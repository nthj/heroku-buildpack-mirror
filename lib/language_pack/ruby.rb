require "tmpdir"
require "rubygems"
require "language_pack"
require "language_pack/base"

# base Ruby Language Pack. This is for any base ruby app.
class LanguagePack::Ruby < LanguagePack::Base
  LIBYAML_VERSION     = "0.1.4"
  LIBYAML_PATH        = "libyaml-#{LIBYAML_VERSION}"
  BUNDLER_VERSION     = "1.2.0.pre"
  BUNDLER_GEM_PATH    = "bundler-#{BUNDLER_VERSION}"
  NODE_VERSION        = "0.4.7"
  NODE_JS_BINARY_PATH = "node-#{NODE_VERSION}"

  # detects if this is a valid Ruby app
  # @return [Boolean] true if it's a Ruby app
  def self.use?
    File.exist?("Gemfile")
  end

  def name
    "Ruby"
  end

  def default_addons
    add_shared_database_addon
  end

  def default_config_vars
    vars = {
      "LANG"     => "en_US.UTF-8",
      "PATH"     => default_path,
      "GEM_PATH" => slug_vendor_base,
    }

    ruby_version_jruby? ? vars.merge("JAVA_OPTS" => default_java_opts) : vars
  end

  def default_process_types
    {
      "rake"    => "bundle exec rake",
      "console" => "bundle exec irb"
    }
  end

  def compile
    Dir.chdir(build_path)
    remove_vendor_bundle
    install_ruby
    setup_language_pack_environment
    allow_git do
      install_language_pack_gems
      # build_bundler
      # create_database_yml
      # install_binaries
      # run_assets_precompile_rake_task
      send_to_ec2
    end
  end

private

  # the base PATH environment variable to be used
  # @return [String] the resulting PATH
  def default_path
    "bin:#{slug_vendor_base}/bin:/usr/local/bin:/usr/bin:/bin"
  end

  # the relative path to the bundler directory of gems
  # @return [String] resulting path
  def slug_vendor_base
    @slug_vendor_base ||= run(%q(ruby -e "require 'rbconfig';puts \"vendor/bundle/#{RUBY_ENGINE}/#{RbConfig::CONFIG['ruby_version']}\"")).chomp
  end

  # the relative path to the vendored ruby directory
  # @return [String] resulting path
  def slug_vendor_ruby
    "vendor/#{ruby_version}"
  end

  # the absolute path of the build ruby to use during the buildpack
  # @return [String] resulting path
  def build_ruby_path
    "/tmp/#{ruby_version}"
  end

  # fetch the ruby version from bundler
  # @return [String, nil] returns the ruby version if detected or nil if none is detected
  def ruby_version
    return @ruby_version if @ruby_version_run

    @ruby_version_run = true

    bootstrap_bundler do |bundler_path|
      old_system_path = "/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
      @ruby_version = run_stdout("env PATH=#{old_system_path}:#{bundler_path}/bin GEM_PATH=#{bundler_path} bundle platform --ruby").chomp
    end

    if @ruby_version == "No ruby version specified" && ENV['RUBY_VERSION']
      # for backwards compatibility.
      # this will go away in the future
      @ruby_version = ENV['RUBY_VERSION']
      @ruby_version_env_var = true
    elsif @ruby_version == "No ruby version specified"
      @ruby_version = nil
    else
      @ruby_version = @ruby_version.sub('(', '').sub(')', '').split.join('-')
      @ruby_version_env_var = false
    end

    @ruby_version
  end

  # bootstraps bundler so we can pull the ruby version
  def bootstrap_bundler(&block)
    Dir.mktmpdir("bundler-") do |tmpdir|
      Dir.chdir(tmpdir) do
        run("curl #{VENDOR_URL}/#{BUNDLER_GEM_PATH}.tgz -s -o - | tar xzf -")
      end

      yield tmpdir
    end
  end

  # determine if we're using rbx
  # @return [Boolean] true if we are and false if we aren't
  def ruby_version_rbx?
    ruby_version ? ruby_version.match(/^rbx-/) : false
  end

  # determine if we're using jruby
  # @return [Boolean] true if we are and false if we aren't
  def ruby_version_jruby?
    @ruby_version_jruby ||= ruby_version ? ruby_version.match(/jruby-/) : false
  end

  # default JAVA_OPTS
  # return [String] string of JAVA_OPTS
  def default_java_opts
    "-Xmx384m -Xss512k -XX:+UseCompressedOops -Dfile.encoding=UTF-8"
  end

  # list the available valid ruby versions
  # @note the value is memoized
  # @return [Array] list of Strings of the ruby versions available
  def ruby_versions
    return @ruby_versions if @ruby_versions

    Dir.mktmpdir("ruby_versions-") do |tmpdir|
      Dir.chdir(tmpdir) do
        run("curl -O #{VENDOR_URL}/ruby_versions.yml")
        @ruby_versions = YAML::load_file("ruby_versions.yml")
      end
    end

    @ruby_versions
  end

  # sets up the environment variables for the build process
  def setup_language_pack_environment
    setup_ruby_install_env

    config_vars = default_config_vars.each do |key, value|
      ENV[key] ||= value
    end
    ENV["GEM_HOME"] = slug_vendor_base
    ENV["PATH"]     = "#{ruby_install_binstub_path}:#{config_vars["PATH"]}"
  end

  # determines if a build ruby is required
  # @return [Boolean] true if a build ruby is required
  def build_ruby?
    @build_ruby ||= !ruby_version_jruby? && ruby_version != "ruby-1.9.3"
  end

  # install the vendored ruby
  # @note this only installs if we detect RUBY_VERSION in the environment
  # @return [Boolean] true if it installs the vendored ruby and false otherwise
  def install_ruby
    return false unless ruby_version

    invalid_ruby_version_message = <<ERROR
Invalid RUBY_VERSION specified: #{ruby_version}
Valid versions: #{ruby_versions.join(", ")}
ERROR

    if build_ruby?
      FileUtils.mkdir_p(build_ruby_path)
      Dir.chdir(build_ruby_path) do
        ruby_vm = ruby_version_rbx? ? "rbx" : "ruby"
        run("curl #{VENDOR_URL}/#{ruby_version.sub(ruby_vm, "#{ruby_vm}-build")}.tgz -s -o - | tar zxf -")
      end
      error invalid_ruby_version_message unless $?.success?
    end

    FileUtils.mkdir_p(slug_vendor_ruby)
    Dir.chdir(slug_vendor_ruby) do
      run("curl #{VENDOR_URL}/#{ruby_version}.tgz -s -o - | tar zxf -")
    end
    error invalid_ruby_version_message unless $?.success?

    bin_dir = "bin"
    FileUtils.mkdir_p bin_dir
    Dir["#{slug_vendor_ruby}/bin/*"].each do |bin|
      run("ln -s ../#{bin} #{bin_dir}")
    end

    if !@ruby_version_env_var
      topic "Using Ruby version: #{ruby_version}"
    else
      topic "Using RUBY_VERSION: #{ruby_version}"
      puts  "WARNING: RUBY_VERSION support has been deprecated and will be removed entirely on August 1, 2012."
      puts  "See https://devcenter.heroku.com/articles/ruby-versions#selecting_a_version_of_ruby for more information."
    end

    true
  end

  # find the ruby install path for its binstubs during build
  # @return [String] resulting path or empty string if ruby is not vendored
  def ruby_install_binstub_path
    @ruby_install_binstub_path ||=
      if build_ruby?
        "#{build_ruby_path}/bin"
      elsif ruby_version
        "#{slug_vendor_ruby}/bin"
      else
        ""
      end
  end

  # setup the environment so we can use the vendored ruby
  def setup_ruby_install_env
    ENV["PATH"] = "#{ruby_install_binstub_path}:#{ENV["PATH"]}"

    if ruby_version_jruby?
      ENV['JAVA_OPTS']  = default_java_opts
    end
  end

  # list of default gems to vendor into the slug
  # @return [Array] resluting list of gems
  def gems
    [BUNDLER_GEM_PATH]
  end

  # installs vendored gems into the slug
  def install_language_pack_gems
    FileUtils.mkdir_p(slug_vendor_base)
    Dir.chdir(slug_vendor_base) do |dir|
      gems.each do |gem|
        run("curl #{VENDOR_URL}/#{gem}.tgz -s -o - | tar xzf -")
      end
      Dir["bin/*"].each {|path| run("chmod 755 #{path}") }
    end
  end

  # default set of binaries to install
  # @return [Array] resulting list
  def binaries
    add_node_js_binary
  end

  # vendors binaries into the slug
  def install_binaries
    binaries.each {|binary| install_binary(binary) }
    Dir["bin/*"].each {|path| run("chmod +x #{path}") }
  end

  # vendors individual binary into the slug
  # @param [String] name of the binary package from S3.
  #   Example: https://s3.amazonaws.com/language-pack-ruby/node-0.4.7.tgz, where name is "node-0.4.7"
  def install_binary(name)
    bin_dir = "bin"
    FileUtils.mkdir_p bin_dir
    Dir.chdir(bin_dir) do |dir|
      run("curl #{VENDOR_URL}/#{name}.tgz -s -o - | tar xzf -")
    end
  end

  # removes a binary from the slug
  # @param [String] relative path of the binary on the slug
  def uninstall_binary(path)
    FileUtils.rm File.join('bin', File.basename(path)), :force => true
  end

  # install libyaml into the LP to be referenced for psych compilation
  # @param [String] tmpdir to store the libyaml files
  def install_libyaml(dir)
    FileUtils.mkdir_p dir
    Dir.chdir(dir) do |dir|
      run("curl #{VENDOR_URL}/#{LIBYAML_PATH}.tgz -s -o - | tar xzf -")
    end
  end

  # remove `vendor/bundle` that comes from the git repo
  # in case there are native ext.
  # users should be using `bundle pack` instead.
  # https://github.com/heroku/heroku-buildpack-ruby/issues/21
  def remove_vendor_bundle
    if File.exists?("vendor/bundle")
      topic "WARNING:  Removing `vendor/bundle`."
      puts  "Checking in `vendor/bundle` is not supported. Please remove this directory"
      puts  "and add it to your .gitignore. To vendor your gems with Bundler, use"
      puts  "`bundle pack` instead."
      FileUtils.rm_rf("vendor/bundle")
    end
  end

  # runs bundler to install the dependencies
  def build_bundler
    log("bundle") do
      bundle_without = ENV["BUNDLE_WITHOUT"] || "development:test"
      bundle_command = "bundle install --without #{bundle_without} --path vendor/bundle --binstubs bin/"

      unless File.exist?("Gemfile.lock")
        error "Gemfile.lock is required. Please run \"bundle install\" locally\nand commit your Gemfile.lock."
      end

      if has_windows_gemfile_lock?
        log("bundle", "has_windows_gemfile_lock")
        File.unlink("Gemfile.lock")
      else
        # using --deployment is preferred if we can
        bundle_command += " --deployment"
        cache_load ".bundle"
      end

      version = run("env RUBYOPT=\"#{syck_hack}\" bundle version").strip
      topic("Installing dependencies using #{version}")

      cache_load "vendor/bundle"

      bundler_output = ""
      Dir.mktmpdir("libyaml-") do |tmpdir|
        libyaml_dir = "#{tmpdir}/#{LIBYAML_PATH}"
        install_libyaml(libyaml_dir)

        # need to setup compile environment for the psych gem
        yaml_include   = File.expand_path("#{libyaml_dir}/include")
        yaml_lib       = File.expand_path("#{libyaml_dir}/lib")
        pwd            = run("pwd").chomp
        # we need to set BUNDLE_CONFIG and BUNDLE_GEMFILE for
        # codon since it uses bundler.
        env_vars       = "env BUNDLE_GEMFILE=#{pwd}/Gemfile BUNDLE_CONFIG=#{pwd}/.bundle/config CPATH=#{yaml_include}:$CPATH CPPATH=#{yaml_include}:$CPPATH LIBRARY_PATH=#{yaml_lib}:$LIBRARY_PATH RUBYOPT=\"#{syck_hack}\""
        puts "Running: #{bundle_command}"
        bundler_output << pipe("#{env_vars} #{bundle_command} --no-clean 2>&1")

      end

      if $?.success?
        log "bundle", :status => "success"
        puts "Cleaning up the bundler cache."
        run "bundle clean"
        cache_store ".bundle"
        cache_store "vendor/bundle"

        # Keep gem cache out of the slug
        FileUtils.rm_rf("#{slug_vendor_base}/cache")
      else
        log "bundle", :status => "failure"
        error_message = "Failed to install gems via Bundler."
        if bundler_output.match(/Installing sqlite3 \([\w.]+\) with native extensions Unfortunately/)
          error_message += <<ERROR


Detected sqlite3 gem which is not supported on Heroku.
http://devcenter.heroku.com/articles/how-do-i-use-sqlite3-for-development
ERROR
        end

        error error_message
      end
    end
  end

  # RUBYOPT line that requires syck_hack file
  # @return [String] require string if needed or else an empty string
  def syck_hack
    syck_hack_file = File.expand_path(File.join(File.dirname(__FILE__), "../../vendor/syck_hack"))
    ruby_version   = run('ruby -e "puts RUBY_VERSION"').chomp
    # < 1.9.3 includes syck, so we need to use the syck hack
    if Gem::Version.new(ruby_version) < Gem::Version.new("1.9.3")
      "-r #{syck_hack_file}"
    else
      ""
    end
  end

  # writes ERB based database.yml for Rails. The database.yml uses the DATABASE_URL from the environment during runtime.
  def create_database_yml
    log("create_database_yml") do
      return unless File.directory?("config")
      topic("Writing config/database.yml to read from DATABASE_URL")
      File.open("config/database.yml", "w") do |file|
        file.puts <<-DATABASE_YML
<%

require 'cgi'
require 'uri'

begin
  uri = URI.parse(ENV["DATABASE_URL"])
rescue URI::InvalidURIError
  raise "Invalid DATABASE_URL"
end

raise "No RACK_ENV or RAILS_ENV found" unless ENV["RAILS_ENV"] || ENV["RACK_ENV"]

def attribute(name, value, force_string = false)
  if value
    value_string =
      if force_string
        '"' + value + '"'
      else
        value
      end
    "\#{name}: \#{value_string}"
  else
    ""
  end
end

adapter = uri.scheme
adapter = "postgresql" if adapter == "postgres"

database = (uri.path || "").split("/")[1]

username = uri.user
password = uri.password

host = uri.host
port = uri.port

params = CGI.parse(uri.query || "")

%>

<%= ENV["RAILS_ENV"] || ENV["RACK_ENV"] %>:
  <%= attribute "adapter",  adapter %>
  <%= attribute "database", database %>
  <%= attribute "username", username %>
  <%= attribute "password", password, true %>
  <%= attribute "host",     host %>
  <%= attribute "port",     port %>

<% params.each do |key, value| %>
  <%= key %>: <%= value.first %>
<% end %>
        DATABASE_YML
      end
    end
  end

  # add bundler to the load path
  # @note it sets a flag, so the path can only be loaded once
  def add_bundler_to_load_path
    return if @bundler_loadpath
    $: << File.expand_path(Dir["#{slug_vendor_base}/gems/bundler*/lib"].first)
    @bundler_loadpath = true
  end

  # detects whether the Gemfile.lock contains the Windows platform
  # @return [Boolean] true if the Gemfile.lock was created on Windows
  def has_windows_gemfile_lock?
    lockfile_parser.platforms.detect do |platform|
      /mingw|mswin/.match(platform.os) if platform.is_a?(Gem::Platform)
    end
  end

  # detects if a gem is in the bundle.
  # @param [String] name of the gem in question
  # @return [String, nil] if it finds the gem, it will return the line from bundle show or nil if nothing is found.
  def gem_is_bundled?(gem)
    @bundler_gems ||= lockfile_parser.specs.map(&:name)
    @bundler_gems.include?(gem)
  end

  # setup the lockfile parser
  # @return [Bundler::LockfileParser] a Bundler::LockfileParser
  def lockfile_parser
    add_bundler_to_load_path
    require "bundler"
    @lockfile_parser ||= Bundler::LockfileParser.new(File.read("Gemfile.lock"))
  end

  # detects if a rake task is defined in the app
  # @param [String] the task in question
  # @return [Boolean] true if the rake task is defined in the app
  def rake_task_defined?(task)
    run("env PATH=$PATH bundle exec rake #{task} --dry-run") && $?.success?
  end

  # executes the block with GIT_DIR environment variable removed since it can mess with the current working directory git thinks it's in
  # param [block] block to be executed in the GIT_DIR free context
  def allow_git(&blk)
    git_dir = ENV.delete("GIT_DIR") # can mess with bundler
    blk.call
    ENV["GIT_DIR"] = git_dir
  end

  # decides if we need to enable the shared database addon
  # @return [Array] the database addon if the pg gem is detected or an empty Array if it isn't.
  def add_shared_database_addon
    gem_is_bundled?("pg") ? ['shared-database:5mb'] : []
  end

  # decides if we need to install the node.js binary
  # @note execjs will blow up if no JS RUNTIME is detected and is loaded.
  # @return [Array] the node.js binary path if we need it or an empty Array
  def add_node_js_binary
    gem_is_bundled?('execjs') ? [NODE_JS_BINARY_PATH] : []
  end

  def run_assets_precompile_rake_task
    if rake_task_defined?("assets:precompile")
      require 'benchmark'

      topic "Running: rake assets:precompile"
      time = Benchmark.realtime { pipe("env PATH=$PATH:bin bundle exec rake assets:precompile 2>&1") }
      if $?.success?
        puts "Asset precompilation completed (#{"%.2f" % time}s)"
      end
    end
  end

  def send_to_ec2
    store_slug and verify_servers_are_online and authorize_deployment do
      failover_servers.each do |server|
        puts "Deploying to #{server}"
        pipe("ssh -i ec2 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -v root@#{server} 'deploy' 2>&1")
      end
    end if sdk_available?
  rescue StandardError, LoadError => e
    puts "Could not deploy to teh EC2s, we are all going to die"
    puts "#{e.class.name}: #{e.message}"
  end

  def authorize_deployment &block
    failover.key_pairs.create(failover_key_name).tap do |key_pair|
      File.open('ec2','w') do |file|
        file.write key_pair.private_key
      end

      File.chmod 0600, 'ec2'
    end

    yield
  ensure
    failover.key_pairs.each do |key_pair|
      key_pair.delete if key_pair.name == failover_key_name
    end
  end

  def store_slug
    base = File.basename Dir.pwd

    puts "Capturing slug archive"
    pipe(" 
      cd ..; 
      tar -czf #{base}.tgz #{base}
    ")

    s3_tools_dir = File.expand_path("../../../support/s3", __FILE__)

    puts "Storing on S3"
    AWS::S3.new(
      access_key_id: ENV['AWS_ACCESS_KEY_ID'],
      secret_access_key: ENV['AWS_SECRET_ACCESS_KEY'],
    ).buckets[ENV['AWS_S3_RELEASES_BUCKET']].objects["#{base}.tgz"].write File.read "../#{base}.tgz"
  end

  def verify_servers_are_online
    unless failover_servers.any?
      puts "No servers are online, deployment pending server spool-up"
    end

    failover_servers.any?
  end

  def failover_key_name
    @failover_key_name ||= "buildpack-key-#{Time.now.usec}"
  end

  def failover_servers
    @failover_servers ||= failover.instances.select do |server|
      server.status == :running
    end.map(&:ip_address)
  end

  def failover
    @failover ||= AWS::EC2.new(
      access_key_id: ENV['AWS_ACCESS_KEY_ID'],
      secret_access_key: ENV['AWS_SECRET_ACCESS_KEY'],
    )
  end

  def sdk_available?
    topic "Forwarding to EC2 failover systems"

    unless ENV['AWS_ACCESS_KEY_ID'] && ENV['AWS_SECRET_ACCESS_KEY'] && ENV['AWS_S3_RELEASES_BUCKET']
      puts "No $AWS_ACCESS_KEY_ID, $AWS_SECRET_ACCESS_KEY, or $AWS_S3_RELEASES_BUCKET, skipping failover deployment" 
      puts "Try running `heroku labs:enable user_env_compile` to make variables available"
      return
    end

    require 'aws'
  rescue LoadError
    # TODO: Cache gem installs
    puts "Could not find aws-sdk gem, installing"
    pipe("gem install aws-sdk --no-ri --no-rdoc")
    Gem.clear_paths

    require 'aws'
  end

  def ip_address
    @ip_address ||= run("hostname -i").chomp
  end
end
