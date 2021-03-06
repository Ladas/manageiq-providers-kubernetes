module ManageIQ::Providers::Kubernetes::ContainerManager::MetricsCapture::PrometheusClientMixin
  require 'faraday'

  def prometheus_client
    @prometheus_uri ||= prometheus_uri
    @prometheus_credentials ||= prometheus_credentials
    @prometheus_options ||= prometheus_options

    prometheus_client_new(@prometheus_uri, @prometheus_credentials, @prometheus_options)
  end

  def prometheus_client_new(uri, credentials, options)
    Faraday.new(
      :url     => uri.to_s,
      :proxy   => options[:http_proxy_uri].empty? ? nil : options[:http_proxy_uri],
      :ssl     => {
        :verify     => options[:verify_ssl] != OpenSSL::SSL::VERIFY_NONE,
        :cert_store => options[:ssl_cert_store]
      },
      :request => {
        :open_timeout => 2, # opening a connection
        :timeout      => 5  # waiting for response
      },
      :headers => {
        :Authorization => "Bearer " + credentials[:token]
      }
    )
  end

  def prometheus_endpoint
    @ext_management_system.endpoints.find_by(:role => "prometheus")
  end

  def prometheus_uri
    URI::HTTPS.build(
      :host => prometheus_endpoint.hostname,
      :port => prometheus_endpoint.port,
      :path => "/api/v1/"
    )
  end

  def prometheus_credentials
    {:token => @ext_management_system.authentication_token("prometheus")}
  end

  def prometheus_options
    {
      :http_proxy_uri => VMDB::Util.http_proxy_uri.to_s,
      :verify_ssl     => @ext_management_system.verify_ssl_mode(prometheus_endpoint),
      :ssl_cert_store => @ext_management_system.ssl_cert_store(prometheus_endpoint),
    }
  end

  def prometheus_try_connect
    prometheus_client.get("query").kind_of?(Hash)
  end
end
