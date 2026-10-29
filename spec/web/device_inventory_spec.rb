require_relative '../spec_helper'
require 'tmpdir'

class InventorySpecCsv
  attr_reader :file, :delimiter, :map, :vars_map

  def initialize(file, delimiter, map, vars_map, gpg)
    @file = file
    @delimiter = delimiter
    @map = map
    @vars_map = vars_map
    @gpg = gpg
  end

  def gpg?
    @gpg
  end
end
InventorySpecConfig = Struct.new(:source)
InventorySpecNodes = Struct.new(:source)

describe Oxidized::API::DeviceInventory do
  before do
    @directory = Dir.mktmpdir('oxidized-web-inventory')
    @path = File.join(@directory, 'router.db')
    @mapping = { name: 0, model: 1, ip: 2, group: 3, username: 4, password: 5, note: 6 }
    @vars_mapping = { enable: 7, description: 8 }
    csv = InventorySpecCsv.new(@path, /:/, @mapping, @vars_mapping, false)
    @config = InventorySpecConfig.new(Struct.new(:csv).new(csv))
    @nodes = InventorySpecNodes.new(:csv)
    @inventory = Oxidized::API::DeviceInventory.new(@nodes, @config)
  end

  after do
    FileUtils.remove_entry(@directory) if File.directory?(@directory)
  end

  it 'persists a mapped device and preserves comments, existing records, and unrelated columns' do
    original = "# inventory comment\nold:ios:192.0.2.1:core:reader:secret:keep:enable-old:old note\n"
    File.binwrite(@path, original)

    refreshes = 0
    @inventory.create(
      name: 'edge-1', model: 'ios', ip: '192.0.2.2', group: 'branch',
      username: 'collector', password: 'device-secret', enable: 'enable-secret',
      description: 'Synthetic device'
    ) { refreshes += 1 }

    rows = File.binread(@path).lines
    _(rows.first).must_equal "# inventory comment\n"
    _(rows[1]).must_equal "old:ios:192.0.2.1:core:reader:secret:keep:enable-old:old note\n"
    _(rows[2]).must_equal "edge-1:ios:192.0.2.2:branch:collector:device-secret::enable-secret:Synthetic device\n"
    _(refreshes).must_equal 1
  end

  it 'rejects duplicate hostnames without changing the inventory' do
    original = "edge-1:ios:192.0.2.1::::::\n"
    File.binwrite(@path, original)

    error = _ { @inventory.create(name: 'edge-1', model: 'ios', ip: '192.0.2.1') }
            .must_raise(Oxidized::API::DeviceInventory::Error)

    _(error.status).must_equal 409
    _(File.binread(@path)).must_equal original
  end

  it 'updates only mapped fields and preserves the remaining columns' do
    original = "# note\nedge-1:ios:192.0.2.1:core:collector:old-secret:custom:enable-old:description\n"
    File.binwrite(@path, original)

    @inventory.update('edge-1', name: 'edge-renamed', ip: '192.0.2.9', password: '')

    _(File.binread(@path)).must_equal "# note\nedge-renamed:ios:192.0.2.9:core:collector:old-secret:custom:enable-old:description\n"
  end

  it 'deletes the selected record while retaining comments and other devices' do
    original = "# note\nedge-1:ios:192.0.2.1::::::\nedge-2:ios:192.0.2.2::::::\n"
    File.binwrite(@path, original)

    @inventory.delete('edge-1')

    _(File.binread(@path)).must_equal "# note\nedge-2:ios:192.0.2.2::::::\n"
  end

  it 'preserves CSV ownership and mode across atomic replacement' do
    skip 'POSIX ownership metadata is unavailable on Windows' if Gem.win_platform?

    File.binwrite(@path, "# metadata\n")
    File.chmod(0o640, @path)
    original_stat = File.stat(@path)

    @inventory.create(name: 'edge-1', model: 'ios', ip: '192.0.2.1')

    updated_stat = File.stat(@path)
    _(updated_stat.mode & 0o7777).must_equal(original_stat.mode & 0o7777)
    _(updated_stat.uid).must_equal original_stat.uid
    _(updated_stat.gid).must_equal original_stat.gid
  end

  it 'requires group to be mapped as a Core node field for bulk assignment' do
    map_without_group = @mapping.except(:group)
    variables_with_group = @vars_mapping.merge(group: 9)
    csv = InventorySpecCsv.new(@path, /:/, map_without_group, variables_with_group, false)
    inventory = Oxidized::API::DeviceInventory.new(@nodes, InventorySpecConfig.new(Struct.new(:csv).new(csv)))

    error = _ { inventory.assign_group(['edge-1'], 'branch') }
            .must_raise(Oxidized::API::DeviceInventory::Error)

    _(error.status).must_equal 409
  end

  it 'restores the original inventory if runtime reload fails' do
    original = "# note\nedge-1:ios:192.0.2.1::::::\n"
    File.binwrite(@path, original)
    calls = 0

    _ do
      @inventory.create(name: 'edge-2', model: 'ios', ip: '192.0.2.2') do
        calls += 1
        raise 'reload failed' if calls == 1
      end
    end.must_raise(RuntimeError)

    _(File.binread(@path)).must_equal original
    _(calls).must_equal 2
  end

  it 'preserves the original file and removes the temporary file when replacement fails' do
    original = "# keep\nedge-1:ios:192.0.2.1::::::\n"
    File.binwrite(@path, original)
    calls = 0
    write = @inventory.method(:atomic_write)
    @inventory.define_singleton_method(:atomic_write) do |contents|
      calls += 1
      raise Errno::EACCES, 'simulated replacement failure' if calls == 1

      write.call(contents)
    end

    error = _ do
      @inventory.create(name: 'edge-2', model: 'ios', ip: '192.0.2.2')
    end.must_raise(Oxidized::API::DeviceInventory::Error)

    _(error.status).must_equal 500
    _(File.binread(@path)).must_equal original
    _(Dir.glob(File.join(@directory, '.router.db.oxidized-web-*'))).must_be_empty
  end

  it 'rejects delimiter injection and unsupported inventory sources' do
    _ do
      @inventory.create(name: 'edge-1', model: 'ios:routeros', ip: '192.0.2.1')
    end.must_raise(Oxidized::API::DeviceInventory::Error)

    sql_nodes = InventorySpecNodes.new(:sql)
    error = _ { Oxidized::API::DeviceInventory.new(sql_nodes, @config) }
            .must_raise(Oxidized::API::DeviceInventory::Error)
    _(error.status).must_equal 409
  end

  it 'serializes concurrent writes under the inventory file lock' do
    File.binwrite(@path, "# concurrent test\n")
    results = Queue.new
    threads = 2.times.map do
      Thread.new do
        @inventory.create(name: 'edge-1', model: 'ios', ip: '192.0.2.1')
        results << :created
      rescue Oxidized::API::DeviceInventory::Error => e
        results << e.status
      end
    end
    threads.each(&:join)

    _(results.pop).must_equal :created
    _(results.pop).must_equal 409
    _(File.binread(@path).lines.count { |line| line.start_with?('edge-1:') }).must_equal 1
  end

  it 'serializes concurrent process writes under the inventory file lock' do
    skip 'Process.fork is unavailable on Windows' unless Process.respond_to?(:fork)

    File.binwrite(@path, "# concurrent process test\n")
    start_reader, start_writer = IO.pipe
    child_processes = 2.times.map do
      Process.fork do
        start_writer.close
        start_reader.read(1)
        begin
          @inventory.create(name: 'edge-1', model: 'ios', ip: '192.0.2.1')
          exit! 0
        rescue Oxidized::API::DeviceInventory::Error => e
          exit!(e.status == 409 ? 42 : 1)
        end
      end
    end
    start_reader.close
    start_writer.write('xx')
    start_writer.close
    exit_codes = child_processes.map { |pid| Process.wait2(pid).last.exitstatus }.sort

    _(exit_codes).must_equal [0, 42]
    _(File.binread(@path).lines.count { |line| line.start_with?('edge-1:') }).must_equal 1
  ensure
    start_reader&.close unless start_reader&.closed?
    start_writer&.close unless start_writer&.closed?
  end
end
