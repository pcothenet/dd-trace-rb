# typed: false
require 'uri'

# NOTE: This code is copied directly from ActiveRecord.
#       Its purpose is to resolve connection information.
#       It exists here only because it doesn't exist in Rails 3.2.
#       When support for Rails 3.2 is dropped, this can be removed.
module Datadog
  module Tracing
    module Contrib
      module ActiveRecord
        module Vendor
          # Copy/paste from:
          # https://github.com/rails/rails/blob/5-2-stable/activerecord/lib/active_record/connection_handling.rb
          module ConnectionHandling
            RAILS_ENV = -> { (Rails.env if defined?(Rails) && defined?(Rails.env)) || ENV["RAILS_ENV"].presence || ENV["RACK_ENV"].presence }
          end

          # Copy/paste from:
          # https://github.com/rails/rails/blob/5-2-stable/activerecord/lib/active_record/connection_adapters/connection_specification.rb
          module ConnectionAdapters
            class ConnectionSpecification
              attr_reader :name, :config, :adapter_method

              def initialize(name, config, adapter_method)
                @name, @config, @adapter_method = name, config, adapter_method
              end

              def initialize_dup(original)
                @config = original.config.dup
              end

              def to_hash
                @config.merge(name: @name)
              end

              # Expands a connection string into a hash.
              class ConnectionUrlResolver # :nodoc:
                # == Example
                #
                #   url = "postgresql://foo:bar@localhost:9000/foo_test?pool=5&timeout=3000"
                #   ConnectionUrlResolver.new(url).to_hash
                #   # => {
                #     "adapter"  => "postgresql",
                #     "host"     => "localhost",
                #     "port"     => 9000,
                #     "database" => "foo_test",
                #     "username" => "foo",
                #     "password" => "bar",
                #     "pool"     => "5",
                #     "timeout"  => "3000"
                #   }
                def initialize(url)
                  raise "Database URL cannot be empty" if url.blank?
                  @uri     = uri_parser.parse(url)
                  @adapter = @uri.scheme && @uri.scheme.tr("-", "_")
                  @adapter = "postgresql" if @adapter == "postgres"

                  if @uri.opaque
                    @uri.opaque, @query = @uri.opaque.split("?", 2)
                  else
                    @query = @uri.query
                  end
                end

                # Converts the given URL to a full connection hash.
                def to_hash
                  config = raw_config.reject { |_, value| value.blank? }
                  config.map { |key, value| config[key] = uri_parser.unescape(value) if value.is_a? String }
                  config
                end

                private

                  def uri
                    @uri
                  end

                  def uri_parser
                    @uri_parser ||= URI::Parser.new
                  end

                  # Converts the query parameters of the URI into a hash.
                  #
                  #   "localhost?pool=5&reaping_frequency=2"
                  #   # => { "pool" => "5", "reaping_frequency" => "2" }
                  #
                  # returns empty hash if no query present.
                  #
                  #   "localhost"
                  #   # => {}
                  def query_hash
                    Hash[(@query || "").split("&").map { |pair| pair.split("=") }]
                  end

                  def raw_config
                    if uri.opaque
                      query_hash.merge(
                        "adapter"  => @adapter,
                        "database" => uri.opaque)
                    else
                      query_hash.merge(
                        "adapter"  => @adapter,
                        "username" => uri.user,
                        "password" => uri.password,
                        "port"     => uri.port,
                        "database" => database_from_path,
                        "host"     => uri.hostname)
                    end
                  end

                  # Returns name of the database.
                  def database_from_path
                    if @adapter == "sqlite3"
                      # 'sqlite3:/foo' is absolute, because that makes sense. The
                      # corresponding relative version, 'sqlite3:foo', is handled
                      # elsewhere, as an "opaque".

                      uri.path
                    else
                      # Only SQLite uses a filename as the "database" name; for
                      # anything else, a leading slash would be silly.

                      uri.path.sub(%r{^/}, "")
                    end
                  end
              end

              ##
              # Builds a ConnectionSpecification from user input.
              class Resolver # :nodoc:
                attr_reader :configurations

                # Accepts a hash two layers deep, keys on the first layer represent
                # environments such as "production". Keys must be strings.
                def initialize(configurations)
                  @configurations = configurations
                end

                # Returns a hash with database connection information.
                #
                # == Examples
                #
                # Full hash Configuration.
                #
                #   configurations = { "production" => { "host" => "localhost", "database" => "foo", "adapter" => "sqlite3" } }
                #   Resolver.new(configurations).resolve(:production)
                #   # => { "host" => "localhost", "database" => "foo", "adapter" => "sqlite3"}
                #
                # Initialized with URL configuration strings.
                #
                #   configurations = { "production" => "postgresql://localhost/foo" }
                #   Resolver.new(configurations).resolve(:production)
                #   # => { "host" => "localhost", "database" => "foo", "adapter" => "postgresql" }
                #
                def resolve(config)
                  if config
                    resolve_connection config
                  elsif env = ConnectionHandling::RAILS_ENV.call
                    resolve_symbol_connection env.to_sym
                  else
                    raise AdapterNotSpecified
                  end
                end

                # Expands each key in @configurations hash into fully resolved hash
                def resolve_all
                  config = configurations.dup

                  if env = ConnectionHandling::DEFAULT_ENV.call
                    env_config = config[env] if config[env].is_a?(Hash) && !(config[env].key?("adapter") || config[env].key?("url"))
                  end

                  config.reject! { |k, v| v.is_a?(Hash) && !(v.key?("adapter") || v.key?("url")) }
                  config.merge! env_config if env_config

                  config.each do |key, value|
                    config[key] = resolve(value) if value
                  end

                  config
                end

                # Returns an instance of ConnectionSpecification for a given adapter.
                # Accepts a hash one layer deep that contains all connection information.
                #
                # == Example
                #
                #   config = { "production" => { "host" => "localhost", "database" => "foo", "adapter" => "sqlite3" } }
                #   spec = Resolver.new(config).spec(:production)
                #   spec.adapter_method
                #   # => "sqlite3_connection"
                #   spec.config
                #   # => { "host" => "localhost", "database" => "foo", "adapter" => "sqlite3" }
                #
                def spec(config)
                  spec = resolve(config).symbolize_keys

                  raise(AdapterNotSpecified, "database configuration does not specify adapter") unless spec.key?(:adapter)

                  # Require the adapter itself and give useful feedback about
                  #   1. Missing adapter gems and
                  #   2. Adapter gems' missing dependencies.
                  path_to_adapter = "active_record/connection_adapters/#{spec[:adapter]}_adapter"
                  begin
                    require path_to_adapter
                  rescue LoadError => e
                    # We couldn't require the adapter itself. Raise an exception that
                    # points out config typos and missing gems.
                    if e.path == path_to_adapter
                      # We can assume that a non-builtin adapter was specified, so it's
                      # either misspelled or missing from Gemfile.
                      raise e.class, "Could not load the '#{spec[:adapter]}' Active Record adapter. Ensure that the adapter is spelled correctly in config/database.yml and that you've added the necessary adapter gem to your Gemfile.", e.backtrace

                    # Bubbled up from the adapter require. Prefix the exception message
                    # with some guidance about how to address it and reraise.
                    else
                      raise e.class, "Error loading the '#{spec[:adapter]}' Active Record adapter. Missing a gem it depends on? #{e.message}", e.backtrace
                    end
                  end

                  adapter_method = "#{spec[:adapter]}_connection"

                  unless ::ActiveRecord::Base.respond_to?(adapter_method)
                    raise AdapterNotFound, "database configuration specifies nonexistent #{spec.config[:adapter]} adapter"
                  end

                  ConnectionSpecification.new(spec.delete(:name) || "primary", spec, adapter_method)
                end

                private

                  # Returns fully resolved connection, accepts hash, string or symbol.
                  # Always returns a hash.
                  #
                  # == Examples
                  #
                  # Symbol representing current environment.
                  #
                  #   Resolver.new("production" => {}).resolve_connection(:production)
                  #   # => {}
                  #
                  # One layer deep hash of connection values.
                  #
                  #   Resolver.new({}).resolve_connection("adapter" => "sqlite3")
                  #   # => { "adapter" => "sqlite3" }
                  #
                  # Connection URL.
                  #
                  #   Resolver.new({}).resolve_connection("postgresql://localhost/foo")
                  #   # => { "host" => "localhost", "database" => "foo", "adapter" => "postgresql" }
                  #
                  def resolve_connection(spec)
                    case spec
                    when Symbol
                      resolve_symbol_connection spec
                    when String
                      resolve_url_connection spec
                    when Hash
                      resolve_hash_connection spec
                    end
                  end

                  # Takes the environment such as +:production+ or +:development+.
                  # This requires that the @configurations was initialized with a key that
                  # matches.
                  #
                  #   Resolver.new("production" => {}).resolve_symbol_connection(:production)
                  #   # => {}
                  #
                  def resolve_symbol_connection(spec)
                    if config = configurations[spec.to_s]
                      resolve_connection(config).merge("name" => spec.to_s)
                    else
                      raise(AdapterNotSpecified, "'#{spec}' database is not configured. Available: #{configurations.keys.inspect}")
                    end
                  end

                  # Accepts a hash. Expands the "url" key that contains a
                  # URL database connection to a full connection
                  # hash and merges with the rest of the hash.
                  # Connection details inside of the "url" key win any merge conflicts
                  def resolve_hash_connection(spec)
                    if spec["url"] && spec["url"] !~ /^jdbc:/
                      connection_hash = resolve_url_connection(spec.delete("url"))
                      spec.merge!(connection_hash)
                    end
                    spec
                  end

                  # Takes a connection URL.
                  #
                  #   Resolver.new({}).resolve_url_connection("postgresql://localhost/foo")
                  #   # => { "host" => "localhost", "database" => "foo", "adapter" => "postgresql" }
                  #
                  def resolve_url_connection(url)
                    ConnectionUrlResolver.new(url).to_hash
                  end
              end
            end
          end
        end
      end
    end
  end
end
