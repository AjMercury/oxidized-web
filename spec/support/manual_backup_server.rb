# Local browser fixture: real Core worker and Git output, synthetic collection only.
ENV['APP_ENV'] = 'test'
$LOAD_PATH.unshift ENV.fetch('CORE_LIB')
$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'oxidized'
require 'oxidized/web'
require 'oxidized/web/webapp'
require 'oxidized/output/git'
require 'puma'
require 'tmpdir'

directory = ENV.fetch('BACKUP_FIXTURE_DIR')
FileUtils.mkdir_p(directory)
Oxidized.asetus = Asetus.new
config = Oxidized.config
config.resolve_dns = false
config.threads = 2
config.use_max_threads = true
config.interval = 0
config.run_once = false
config.retries = 0
config.timelimit = 20
config.next_adds_job = true
config.output.git.repo = File.join(directory, 'configs.git')
config.output.git.user = 'Synthetic QA'
config.output.git.email = 'qa@example.invalid'
config.source.default = 'csv'
config.source.csv.file = File.join(directory, 'inventory.csv')
config.source.csv.delimiter = ':'
config.source.csv.map = { name: 0, model: 1, ip: 2 }
config.source.csv.vars_map = {}
Oxidized.mgr = Oxidized::Manager.new
Oxidized.hooks = Oxidized::HookManager.from_config(config)
items = (1..23).map do |number|
  node = Oxidized::Node.new(name: "device-#{number}", ip: "192.0.2.#{number}", model: number.odd? ? 'ios' : 'routeros', input: 'ssh', output: 'git')
  node.define_singleton_method(:run) do
    sleep 0.35
    outputs = Oxidized::Model::Outputs.new
    override = File.join(directory, "#{name}.txt")
    description = File.file?(override) ? File.read(override).strip : 'synthetic fixture'
    outputs << "hostname #{name}\ninterface Ethernet1\n description #{description}\n"
    [name == 'device-23' ? :no_connection : :success, outputs]
  end
  node
end
File.write(config.source.csv.file, items.map { |node| "#{node.name}:#{node.model.class.to_s.downcase}:#{node.ip}" }.join("\n"))
nodes = Oxidized::Nodes.new(nodes: items)
nodes.source = 'csv'
worker = Oxidized::Worker.new(nodes)
Thread.new do
  loop do
    worker.work
    sleep 0.1
  end
end
store = Oxidized::API::UserStore.new(File.join(directory, 'users.sqlite3'))
if store.user_count.zero?
  store.create_initial_admin('fixture-admin', 'synthetic-password-123')
  store.create_user(username: 'fixture-viewer', password: 'synthetic-password-123', role: 'viewer')
end
app = Oxidized::API::WebApp
app.set :nodes, nodes
app.set :auth_store, store
app.set :auth_require_https, true
app.set :trusted_proxies, ['127.0.0.1']
server = Puma::Server.new(app)
server.add_tcp_listener '127.0.0.1', Integer(ENV.fetch('BACKUP_FIXTURE_PORT', '45528'))
server.run.join
