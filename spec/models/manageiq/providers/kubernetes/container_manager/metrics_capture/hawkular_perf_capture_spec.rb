shared_examples "kubernetes perf capture specs" do
  before(:each) do
    hostname = "ladislav-ocp-3.6-master01.10.35.49.17.nip.io"
    hawkular_hostname = "hawkular-metrics.10.35.49.18.nip.io"
    token    = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJrdWJlcm5ldGVzL3NlcnZpY2VhY2NvdW50Iiwia3ViZXJuZXRlcy5pby9zZXJ2aWNlYWNjb3VudC9uYW1lc3BhY2UiOiJtYW5hZ2VtZW50LWluZnJhIiwia3ViZXJuZXRlcy5pby9zZXJ2aWNlYWNjb3VudC9zZWNyZXQubmFtZSI6Im1hbmFnZW1lbnQtYWRtaW4tdG9rZW4tNmo4NTUiLCJrdWJlcm5ldGVzLmlvL3NlcnZpY2VhY2NvdW50L3NlcnZpY2UtYWNjb3VudC5uYW1lIjoibWFuYWdlbWVudC1hZG1pbiIsImt1YmVybmV0ZXMuaW8vc2VydmljZWFjY291bnQvc2VydmljZS1hY2NvdW50LnVpZCI6IjdkYzIwZGM2LWE2YzAtMTFlNy04ZGU2LTAwMWE0YTE2MjcxMSIsInN1YiI6InN5c3RlbTpzZXJ2aWNlYWNjb3VudDptYW5hZ2VtZW50LWluZnJhOm1hbmFnZW1lbnQtYWRtaW4ifQ.Cuf_1soEiFIFEwXkZy3B-xBlgk63nc4QckylCQBsbjNXVy3RULKzpqpXYDpOjtacbo0KDX2p50n9cOtj5zwyR31EAAmAU8IoJXHpytOrdsJrmRe6ZZSUBq12Fq44dV5zdhey5k5jQ_VFlicKUqPW8jiQb_tBUQPX1co5DWsQJ8hDuWik84QBMG8DkY2fpc8IG6vIM02tNIMa0dgAXAyntkRRedezhnBYBSI5RqDkqKT7Kmae9rcjeXiwhhKFLDAVDDiCUdPpbNG4I7Brz1LhYKLyKP2SVT1rrvzx9CCxs2a2jfeY_fAzgyT_UbwRTSPvpBpa2TcEbowuW21vLtKvVg"

    allow(MiqServer).to receive(:my_zone).and_return("default")

    @ems = FactoryGirl.create(
      :ems_kubernetes,
      :name                      => 'KubernetesProvider',
      :connection_configurations => [{:endpoint       => {:role       => :default,
                                                          :hostname   => hostname,
                                                          :port       => "8443",
                                                          :verify_ssl => false},
                                      :authentication => {:role     => :bearer,
                                                          :auth_key => token,
                                                          :userid   => "_"}},
                                     {:endpoint       => {:role       => :hawkular,
                                                          :hostname   => hawkular_hostname,
                                                          :port       => "443",
                                                          :verify_ssl => false},
                                      :authentication => {:role     => :hawkular,
                                                          :auth_key => token,
                                                          :userid   => "_"}}]
    )

    # If re-recording the VCR, add <3.days.ago.utc, Time.now.utc>
    # @start_time = Time.parse("2017-10-01 16:24:57 UTC")
    # @end_time   = Time.parse("2017-10-03 16:24:58 UTC")
    @start_time = Time.parse("2017-10-01 17:00:00 UTC")
    @end_time   = Time.parse("2017-10-03 17:00:00 UTC")


    # Entities of interest
    @container_name = 'kibana'
    @container_node_name = "ladislav-ocp-3.6-infra02.10.35.49.19.nip.io"
  end

  def refresh
    VCR.use_cassette("#{described_class.name.underscore}_perf_capture_refresh") do
      EmsRefresh.refresh(@ems)
    end
  end

  # Compare MIQ hourly rollups based on realtime data, with hourly rollups made by hawkular API, with hourly rollups
  # computed here manually based on real samples

  # Given samples
  # 17:00 | 18:00 | 19:00 | 20:00
  # ==============================
  #
  # we were doing
  #   (17:00, avg) - (16:00, avg) setting it on <17:00, 18:00> avg percentage (after the percentage computation)
  # though with linear cpu rise (for simplicity) it would really give us
  #   <16:30, 17:30> avg percentage, that sounds as not correct (the normal cpu is non linear, so the times can be
  #   anything)
  # ------
  # the more correct way should be (using 1.hour before max, so we do not miss any sample and the diff is continuous)
  #   (17:00, max) - (16:00, max), setting it as <17:00, 18:00> avg percentage (after the percentage computation)
  # then this will give us
  #   <17:00 (- max 30s), 18:00 (- max 30s)> avg percentage, so it is much closer to the average of that particular
  #   hour. The - max 30s means, the last 'max' sample won't be always at beginning_of_hour, but moved by the sampling
  #   period.
  def perf_capture_containers
    miq_rollups    = nil
    api_rollups    = nil
    manual_rollups = nil

    hourly_metrics = nil
    rollups_jobs = nil

    container = Container.find_by(:name => @container_name)

    VCR.use_cassette("#{described_class.name.underscore}_perf_capture_miq_rollups") do
      # Collect realtime data
      container.perf_capture("realtime", @start_time, @end_time)

      # Deliver hourly rollup jobs added to MiqQueue by perf_capture
      rollups_jobs = MiqQueue.where(:method_name => "perf_rollup").select { |x| x.deliver_on < @end_time && x.args[1] == "hourly" }.to_a
      rollups_jobs.each(&:deliver)

      # Store MIQ made rollups for comparision
      miq_rollups = container.metric_rollups.order(:timestamp).to_a
    end

    # Remove rollups from the DB, and fetch them again directly from the Hawkular API
    MetricRollup.delete_all
    VimPerformanceState.delete_all
    container.reload

    VCR.use_cassette("#{described_class.name.underscore}_perf_capture_api_rollups") do
      # Get just the metrics
      hourly_metrics = container.perf_collect_metrics("hourly", @start_time.beginning_of_hour, @end_time.beginning_of_hour - 1.hour)

      # Get hourly rollups directly from the API
      container.perf_capture("hourly", @start_time.beginning_of_hour, @end_time.beginning_of_hour - 1.hour)

      # Store API made rollups for comparision
      api_rollups = container.metric_rollups.order(:timestamp).to_a
    end

    VCR.use_cassette("#{described_class.name.underscore}_perf_capture_manual_rollups") do
      # Get hourly rollups directly from the API
      raw_metrics = container.perf_collect_metrics("realtime", @start_time, @end_time)

      # TODO(lsmola) raw_metrics count and Metric count for 1 hour are +-1
      # TODO(lsmola) I have to do (key >= @start_time.beginning_of_hour + 1.hour - 19.seconds) , since the xx:57 goes to xy:00 of a next minute, therefore next hourly rollup for 1 sample
      first_hour_miq_like = raw_metrics.second[container.ems_ref].select {|key, value| (key >= @start_time.beginning_of_hour + 1.hour - 19.seconds) && (key <= @start_time.beginning_of_hour + 2.hours - 19.seconds) }
      first_hour_miq_like_avg_cpu = first_hour_miq_like.sum{|key, value| value["cpu_usage_rate_average"]} / first_hour_miq_like.count
      first_hour_miq_like_avg_mem = first_hour_miq_like.sum{|key, value| value["mem_usage_absolute_average"]} / first_hour_miq_like.count

      first_hour_correct = raw_metrics.second[container.ems_ref].select {|key, value| (key >= @start_time.beginning_of_hour + 1.hour) && (key <= @start_time.beginning_of_hour + 2.hours) }
      first_hour_correct_avg_cpu = first_hour_correct.sum{|key, value| value["cpu_usage_rate_average"]} / first_hour_correct.count
      first_hour_correct_avg_mem = first_hour_correct.sum{|key, value| value["mem_usage_absolute_average"]} / first_hour_correct.count

      pp Metric.where("timestamp" => @start_time.beginning_of_hour + 1.hour..@start_time.beginning_of_hour + 2.hours).order(:timestamp).map{|x| x.timestamp}


      obj = ManageIQ::Providers::Kubernetes::ContainerManager::MetricsCapture::HawkularCaptureContext.new(container, @start_time.beginning_of_hour, @end_time.beginning_of_hour, 3600)

      group_id = container.container_group.ems_ref

      cpu_resid    = "#{container.name}/#{group_id}/cpu/usage"
      node_cores = container.try(:container_node).try(:hardware).try(:cpu_total_cores)
      total_cpu_time = node_cores * 1e09 * 3600.seconds.to_i
      api_raw_data = obj.fetch_counters_data(cpu_resid)
      api_raw_data.each_cons(2).each do |prev, x|
        timestamp = Time.at(prev['start'] / 1.in_milliseconds).utc
        avg_usage = ((x['avg'] - prev['avg']) * 100.0) / total_cpu_time
        byebug
      end

      byebug
      # Store API made rollups for comparision
      manual_rollups = raw_metrics
    end

    byebug
    miq_rollups
    api_rollups
    manual_rollups
  end

  def perf_capture_nodes
    container_node = @ems.container_nodes.find_by(:name => @container_node_name)

    container_node.perf_capture("realtime", @start_time, @end_time)

    byebug
  end

  it "will poerform perf capture" do
    refresh
    perf_capture_containers
    perf_capture_nodes
  end
end

describe ManageIQ::Providers::Kubernetes::ContainerManager::MetricsCapture::HawkularClient do
  context "perf_capture containers" do
    # before(:each) do
    #   stub_settings_merge(
    #     :ems_refresh => {:kubernetes => {:inventory_object_refresh => false}}
    #   )
    #
    #   expect(ManageIQ::Providers::Kubernetes::ContainerManager::RefreshParser).not_to receive(:ems_inv_to_inv_collections)
    # end

    include_examples "kubernetes perf capture specs"
  end
end
