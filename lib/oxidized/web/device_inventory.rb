# frozen_string_literal: true

require 'fileutils'
require 'ipaddr'
require 'securerandom'
require 'csv'

module Oxidized
  module API
    class DeviceInventory
      class Error < StandardError
        attr_reader :status

        def initialize(message, status: 422)
          super(message)
          @status = status
        end
      end

      def initialize(nodes, configuration)
        @nodes = nodes
        source = nodes.source.to_s.downcase
        raise Error.new('Device management supports only a CSV inventory source.', status: 409) unless source == 'csv'

        @csv = configuration.source.csv
        raise Error.new('Encrypted CSV inventories are read-only.', status: 409) if @csv.gpg?

        @path = File.expand_path(@csv.file)
        @delimiter = @csv.delimiter
        @delimiter_text = serializable_delimiter(@delimiter)
        @map = normalize_mapping(@csv.map)
        @vars_map = normalize_mapping(@csv.vars_map)
        raise Error.new('A CSV field cannot be mapped as both a node field and a node variable.', status: 409) unless (@map.keys & @vars_map.keys).empty?

        missing = %i[name model ip] - @map.keys
        return if missing.empty?

        raise Error.new(
          "Device management is read-only because source.csv.map is missing required Core fields: #{missing.join(', ')}. Add explicit zero-based column mappings for name, model, and ip using the existing CSV column order, then restart Oxidized. No inventory data was changed.",
          status: 409
        )
      end

      def fields
        @map.merge(@vars_map).sort_by { |field, index| [index, field.to_s] }.map { |field, _index| field.to_s }
      end

      def group_assignable?
        @map.has_key?(:group)
      end

      def create(attributes, &refresh)
        attrs = validate_attributes(attributes, require_name: true)
        rewrite(refresh: refresh) do |contents|
          lines = contents.lines
          raise Error.new('The configured CSV inventory file does not exist.', status: 409) unless File.file?(@path)
          raise Error.new('A device with this hostname already exists.', status: 409) if locate(lines, attrs[:name])

          append_row(contents, serialize_row(attrs, contents))
        end
      end

      def import_template
        CSV.generate_line(fields)
      end

      def import_csv(contents, validate: nil, &refresh)
        csv_contents = contents.to_s.dup.force_encoding(Encoding::UTF_8)
        raise Error, 'The import file must use valid UTF-8 encoding.' unless csv_contents.valid_encoding?

        rows = begin
          CSV.parse(csv_contents, skip_blanks: true)
        rescue CSV::MalformedCSVError, ArgumentError
          raise Error, 'The import file is not valid CSV. Check its quoting and separators.'
        end
        headers = Array(rows.shift).map { |header| header.to_s.strip }
        headers[0] = headers[0].delete_prefix("\uFEFF") if headers.any?
        raise Error, 'The import file must include the downloaded CSV template header.' if headers.empty? || headers.any?(&:empty?)
        raise Error, 'The import file contains duplicate column headers.' unless headers.uniq.length == headers.length

        unsupported = headers - fields
        raise Error, 'The import file contains columns that are not available in the current inventory template.' unless unsupported.empty?

        missing = %w[name model ip] - headers
        raise Error, "The import file is missing required columns: #{missing.join(', ')}." unless missing.empty?

        raise Error, 'The import file does not contain any devices.' if rows.empty?
        raise Error, 'The import file cannot contain more than 10000 devices.' if rows.length > 10_000

        records = rows.each_with_index.map do |row, index|
          if row.length > headers.length
            raise Error, "Row #{index + 2}: contains more columns than the CSV template header."
          end

          attributes = headers.each_with_index.to_h { |field, column| [field.to_sym, row[column].to_s] }
          begin
            validated = validate_attributes(attributes, require_name: true)
            validate&.call(validated)
            validated
          rescue Error => e
            raise Error, "Row #{index + 2}: #{e.message}"
          end
        end

        rewrite(
          refresh: -> { refresh&.call(records.map { |record| record[:name] }) },
          rollback_refresh: -> { refresh&.call(nil) }
        ) do |contents|
          raise Error.new('The configured CSV inventory file does not exist.', status: 409) unless File.file?(@path)

          lines = contents.lines
          existing_name_counts = Hash.new(0)
          lines.each do |line|
            next if line.match?(/^\s*#/) || line.strip.empty?

            name = line.chomp.split(@delimiter, -1)[@map.fetch(:name)].to_s
            existing_name_counts[name] += 1
          end
          imported_names = {}
          records.each_with_index do |record, index|
            name = record.fetch(:name)
            raise Error, "Row #{index + 2}: the hostname appears more than once in the import file." if imported_names.key?(name)

            existing_count = existing_name_counts[name]
            if existing_count > 1
              raise Error.new("Row #{index + 2}: the inventory already contains multiple records with this hostname.", status: 409)
            elsif existing_count == 1
              raise Error.new("Row #{index + 2}: a device with this hostname already exists.", status: 409)
            end

            imported_names[name] = true
          end

          mappings = @map.merge(@vars_map)
          existing_width = lines.reject { |line| line.match?(/^\s*#/) || line.strip.empty? }
                                .map { |line| line.chomp.split(@delimiter, -1).length }.max || 0
          row_width = [(mappings.values.max || 0) + 1, existing_width].max
          rows = records.map { |record| serialize_row(record, contents, width: row_width) }
          ending = contents.include?("\r\n") ? "\r\n" : "\n"
          prefix = contents.empty? || contents.end_with?("\n") ? '' : ending
          "#{contents}#{prefix}#{rows.join(ending)}#{ending}"
        end
        records.length
      end

      def update(name, attributes, &refresh)
        attrs = validate_attributes(attributes, require_name: false)
        rewrite(refresh: refresh) do |contents|
          lines = contents.lines
          index = locate(lines, name)
          raise Error.new('Device was not found in the configured inventory.', status: 404) unless index
          raise Error.new('A device with this hostname already exists.', status: 409) if attrs[:name] && attrs[:name] != name && locate(lines, attrs[:name])

          current_values = lines[index].chomp.split(@delimiter, -1)
          model_value = attrs.fetch(:model, current_values[@map.fetch(:model)]).to_s
          address_value = attrs.fetch(:ip, current_values[@map.fetch(:ip)]).to_s
          raise Error, 'Model is required.' if model_value.empty?
          raise Error, 'Management address is required.' if address_value.empty?

          lines[index] = update_row(lines[index], attrs)
          lines.join
        end
      end

      def delete(name, &refresh)
        delete_many([name], &refresh)
      end

      def delete_many(names, &refresh)
        requested = names.map(&:to_s).uniq
        rewrite(refresh: refresh) do |contents|
          lines = contents.lines
          indexes = requested.map do |name|
            index = locate(lines, name)
            raise Error.new("Device '#{name}' was not found in the configured inventory.", status: 404) unless index

            index
          end
          indexes.sort.reverse_each { |index| lines.delete_at(index) }
          lines.join
        end
      end

      def assign_group(names, group, &refresh)
        attrs = validate_attributes({ group: group }, require_name: false)
        raise Error.new('Device group is not mapped as a node field in the configured CSV source.', status: 409) unless group_assignable?

        requested = names.map(&:to_s).uniq
        rewrite(refresh: refresh) do |contents|
          lines = contents.lines
          indexes = requested.to_h do |name|
            index = locate(lines, name)
            raise Error.new("Device '#{name}' was not found in the configured inventory.", status: 404) unless index

            [index, name]
          end
          indexes.each_key { |index| lines[index] = update_row(lines[index], attrs) }
          lines.join
        end
      end

      private

      def normalize_mapping(mapping)
        normalized = {}
        mapping.each do |key, position|
          index = Integer(position)
          raise Error.new('CSV field mappings must use non-negative integer positions.', status: 409) if index.negative?

          normalized[key.to_s.to_sym] = index
        rescue ArgumentError, TypeError
          raise Error.new('CSV field mappings must use non-negative integer positions.', status: 409)
        end
        normalized
      end

      def serializable_delimiter(delimiter)
        value = if delimiter.is_a?(Regexp)
                  delimiter.source
                else
                  delimiter.to_s
                end
        raise Error.new('The configured CSV delimiter cannot be safely written by the Web UI.', status: 409) if value.empty? || value.match?(/[\r\n\0]/) || (delimiter.is_a?(Regexp) && Regexp.escape(value) != value)

        value
      end

      def validate_attributes(attributes, require_name:)
        values = attributes.each_with_object({}) do |(key, value), result|
          field = key.to_s.to_sym
          result[field] = %i[password enable].include?(field) ? value.to_s : value.to_s.strip
        end
        allowed = fields.map(&:to_sym)
        unsupported = values.keys - allowed
        raise Error.new("Unsupported CSV fields: #{unsupported.join(', ')}", status: 409) unless unsupported.empty?

        values.each { |field, value| validate_atom!(field, value) unless value.empty? }

        name = values[:name]
        raise Error, 'Hostname is required.' if require_name && name.to_s.empty?
        raise Error, 'Hostname is required.' if values.has_key?(:name) && name.to_s.empty?

        validate_hostname(name) if name

        validate_address(values[:ip]) unless values[:ip].to_s.empty?
        validate_group(values[:group]) unless values[:group].to_s.empty?
        validate_input(values[:input]) unless values[:input].to_s.empty?
        %i[ssh_port telnet_port].each do |key|
          validate_port(values[key]) unless values[key].to_s.empty?
        end
        validate_timeout(values[:timeout]) unless values[:timeout].to_s.empty?

        if require_name
          raise Error, 'Model is required.' if values[:model].to_s.empty?
          raise Error, 'Management address is required.' if @map.has_key?(:ip) && values[:ip].to_s.empty?
        end
        values.reject { |key, value| value.empty? && %i[username password enable].include?(key) }
      end

      def validate_atom!(field, value)
        return unless value.include?(@delimiter_text) || value.match?(/[\r\n\0]/)

        raise Error, "#{field.to_s.capitalize} contains a character that cannot be stored in this CSV format."
      end

      def validate_hostname(value)
        validate_atom!(:name, value)
        pattern = /\A[a-zA-Z0-9](?:[a-zA-Z0-9_.-]{0,251}[a-zA-Z0-9])?\z/
        raise Error, 'Hostname contains unsupported characters.' unless pattern.match?(value) && value != '.' && value != '..'
      end

      def validate_group(value)
        validate_atom!(:group, value)
        segments = value.split('/', -1)
        valid = !value.start_with?('/') && !value.end_with?('/') &&
                segments.all? { |segment| segment.match?(/\A[a-zA-Z0-9_.-]+\z/) && segment != '.' && segment != '..' }
        raise Error, 'Device group contains an unsafe path segment.' unless valid
      end

      def validate_input(value)
        inputs = value.split(',').map(&:strip)
        raise Error, 'Connection protocol must be ssh or telnet.' unless inputs.all? { |input| %w[ssh telnet].include?(input) }
      end

      def validate_port(value)
        port = Integer(value, 10)
        raise Error, 'Connection port must be between 1 and 65535.' unless (1..65_535).cover?(port)
      rescue ArgumentError
        raise Error, 'Connection port must be between 1 and 65535.'
      end

      def validate_timeout(value)
        timeout = Integer(value, 10)
        raise Error, 'Connection timeout must be between 1 and 3600 seconds.' unless (1..3600).cover?(timeout)
      rescue ArgumentError
        raise Error, 'Connection timeout must be between 1 and 3600 seconds.'
      end

      def validate_address(value)
        IPAddr.new(value)
      rescue IPAddr::InvalidAddressError
        hostname = /\A[a-zA-Z0-9](?:[a-zA-Z0-9.-]{0,251}[a-zA-Z0-9])?\z/
        raise Error, 'Management address must be an IP address or hostname.' unless hostname.match?(value)
      end

      def locate(lines, name)
        indices = lines.each_index.select do |index|
          line = lines[index]
          next false if line.match?(/^\s*#/) || line.strip.empty?

          fields = line.chomp.split(@delimiter, -1)
          fields[@map.fetch(:name)].to_s == name
        end
        raise Error.new('The inventory contains multiple records with this hostname.', status: 409) if indices.size > 1

        indices.first
      end

      def serialize_row(attributes, contents, width: nil)
        mappings = @map.merge(@vars_map)
        unless width
          existing_lines = contents.lines.reject { |line| line.match?(/^\s*#/) || line.strip.empty? }
          existing_width = existing_lines.map { |line| line.chomp.split(@delimiter, -1).length }.max || 0
          width = [(mappings.values.max || 0) + 1, existing_width].max
        end
        columns = Array.new(width, '')
        mappings.each do |key, index|
          columns[index] = attributes[key].to_s if attributes.has_key?(key)
        end
        columns.join(@delimiter_text)
      end

      def update_row(line, attributes)
        columns = line.chomp.split(@delimiter, -1)
        mappings = @map.merge(@vars_map)
        attributes.each do |key, value|
          next unless mappings.has_key?(key)

          index = mappings.fetch(key)
          columns.fill('', columns.length...index) if index >= columns.length
          columns[index] = value
        end
        ending = if line.end_with?("\r\n")
                   "\r\n"
                 else
                   (line.end_with?("\n") ? "\n" : '')
                 end
        columns.join(@delimiter_text) + ending
      end

      def append_row(contents, row)
        ending = contents.include?("\r\n") ? "\r\n" : "\n"
        prefix = contents.empty? || contents.end_with?("\n") ? '' : ending
        "#{contents}#{prefix}#{row}#{ending}"
      end

      def rewrite(refresh:, rollback_refresh: refresh)
        raise Error.new('The configured CSV inventory file is not writable.', status: 409) unless File.file?(@path) && File.writable?(@path)
        raise Error.new('A symbolic link cannot be modified through device management.', status: 409) if File.symlink?(@path)

        lock_path = "#{@path}.web.lock"
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          original = File.binread(@path)
          updated = yield original
          return false if updated == original

          begin
            atomic_write(updated)
            refresh&.call
          rescue StandardError => e
            atomic_write(original)
            begin
              rollback_refresh&.call
            rescue StandardError => rollback_error
              raise Error.new("Inventory update was rolled back, but Core could not restore its in-memory inventory: #{rollback_error.class}.", status: 500)
            end
            raise e
          end
          true
        end
      rescue Error
        raise
      rescue SystemCallError => e
        raise Error.new("Unable to update the configured CSV inventory: #{e.class}.", status: 500)
      end

      def atomic_write(contents)
        original_stat = File.stat(@path)
        directory = File.dirname(@path)
        temporary = File.join(directory, ".#{File.basename(@path)}.oxidized-web-#{SecureRandom.hex(8)}")
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o600) do |file|
          file.write(contents)
          file.flush
          file.fsync
        end
        unless Gem.win_platform?
          begin
            File.chown(original_stat.uid, original_stat.gid, temporary)
          rescue Errno::EPERM
            # A group-writable source may be owned by root while the service
            # account can replace it through directory permissions. Preserve
            # the shared group in that case; fail safely if that is not allowed.
            File.chown(-1, original_stat.gid, temporary)
          end
          File.chmod(original_stat.mode & 0o7777, temporary)
        end
        File.rename(temporary, @path)
      ensure
        File.delete(temporary) if temporary && File.exist?(temporary)
      end
    end
  end
end
