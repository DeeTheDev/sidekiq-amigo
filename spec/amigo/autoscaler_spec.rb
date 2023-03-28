# frozen_string_literal: true

require "timecop"

require "amigo/autoscaler"

RSpec.describe Amigo::Autoscaler do
  def instance(**kw)
    described_class.new(poll_interval: 0, handlers: ["test"], **kw)
  end

  before(:all) do
    Sidekiq::Testing.inline!
    @dyno = ENV.fetch("DYNO", nil)
  end

  after(:each) do
    ENV["DYNO"] = @dyno
  end

  def fake_q(name, latency)
    cls = Class.new do
      define_method(:name) { name }
      define_method(:latency) { latency }
    end
    return cls.new
  end

  describe "initialize" do
    it "errors for a negative or 0 latency_threshold" do
      expect do
        described_class.new(latency_threshold: -1)
      end.to raise_error(ArgumentError)
    end

    it "errors for a negative latency_restored_threshold" do
      expect do
        described_class.new(latency_restored_threshold: -1)
      end.to raise_error(ArgumentError)
    end

    it "errors if the latency restored threshold is > latency threshold" do
      expect do
        described_class.new(latency_threshold: 100, latency_restored_threshold: 101)
      end.to raise_error(ArgumentError)
    end

    it "defaults latency restored threshold to latency threshold" do
      x = described_class.new(latency_threshold: 100)
      expect(x).to have_attributes(latency_restored_threshold: 100)
    end
  end

  describe "start" do
    it "starts a polling thread if the dyno env var matches the given regex" do
      allow(Sidekiq::Queue).to receive(:all).and_return([fake_q("x", 0)])

      ENV["DYNO"] = "foo.123"
      o = instance(hostname_regex: /^foo\.123$/)
      expect(o.start).to be_truthy
      expect(o.polling_thread).to be_a(Thread)
      o.polling_thread.kill

      o = instance
      ENV["DYNO"] = "foo.12"
      expect(o.start).to be_falsey
      expect(o.polling_thread).to be_nil
    end

    it "starts a polling thread if the hostname matches the given regex" do
      allow(Sidekiq::Queue).to receive(:all).and_return([fake_q("x", 0)])

      expect(Socket).to receive(:gethostname).and_return("foo.123")
      o = instance(hostname_regex: /^foo\.123$/)
      expect(o.start).to be_truthy
      expect(o.polling_thread).to be_a(Thread)
      o.polling_thread.kill

      expect(Socket).to receive(:gethostname).and_return("foo.12")
      o = instance
      expect(o.start).to be_falsey
      expect(o.polling_thread).to be_nil
    end
  end

  describe "check" do
    it "noops if there are no high latency queues" do
      expect(Sidekiq::Queue).to receive(:all).and_return([fake_q("x", 1)])
      o = instance
      expect(o).to_not receive(:alert_test)
      o.setup
      o.check
    end

    it "alerts about high latency queues" do
      expect(Sidekiq::Queue).to receive(:all).and_return([fake_q("x", 1), fake_q("y", 20)])
      o = instance
      expect(o).to receive(:alert_test).with({"y" => 20}, duration: 0, depth: 1)
      o.setup
      o.check
    end

    it "keeps track of duration and depth after multiple alerts" do
      expect(Sidekiq::Queue).to receive(:all).twice.and_return([fake_q("y", 20)])
      o = instance(alert_interval: 0)
      expect(o).to receive(:alert_test).with({"y" => 20}, duration: 0, depth: 1)
      o.setup
      o.check
      sleep 0.1
      expect(o).to receive(:alert_test).with({"y" => 20}, duration: be > 0.05, depth: 2)
      o.check
    end

    it "alerts with keywords when handlers have keyword (2) arity" do
      expect(Sidekiq::Queue).to receive(:all).and_return([fake_q("y", 20)])
      got = []
      handler = ->(q, kw) { got << [q, kw] }
      o = instance(handlers: [handler])
      o.setup
      o.check
      expect(got).to eq([[{"y" => 20}, {depth: 1, duration: 0.0}]])
    end

    it "alerts with keywords when handlers have splat arity" do
      expect(Sidekiq::Queue).to receive(:all).and_return([fake_q("y", 20)])
      got = []
      handler = proc { |*a| got << a }
      o = instance(handlers: [handler])
      o.setup
      o.check
      expect(got).to eq([[{"y" => 20}, {depth: 1, duration: 0.0}]])
    end

    it "alerts without depth when handlers have no keyword (1) arity" do
      expect(Sidekiq::Queue).to receive(:all).and_return([fake_q("y", 20)])
      got = []
      handler = ->(q) { got << q }
      o = instance(handlers: [handler])
      o.setup
      o.check
      expect(got).to eq([{"y" => 20}])
    end

    it "noops if recently alerted" do
      expect(Sidekiq::Queue).to receive(:all).
        twice.
        and_return([fake_q("x", 1), fake_q("y", 20)])
      now = Time.now
      o = instance(alert_interval: 120)
      expect(o).to receive(:alert_test).twice
      o.setup
      Timecop.freeze(now) { o.check }
      Timecop.freeze(now + 60) { o.check }
      Timecop.freeze(now + 180) { o.check }
    end

    it "invokes latency restored handlers once all queues have a latency at/below the threshold" do
      expect(Sidekiq::Queue).to receive(:all).
        and_return([fake_q("y", 20)], [fake_q("y", 3)], [fake_q("y", 2)])
      o = instance(alert_interval: 0, latency_threshold: 2)
      expect(o).to receive(:alert_test).with({"y" => 20}, duration: be_a(Float), depth: 1)
      expect(o).to receive(:alert_test).with({"y" => 3}, duration: be_a(Float), depth: 2)
      expect(o).to receive(:alert_restored_log).with(duration: be_a(Float), depth: 2)
      o.setup
      o.check
      o.check
      o.check
    end
  end

  describe "alert_log" do
    after(:each) do
      Amigo.reset_logging
    end

    it "logs" do
      Amigo.structured_logging = true
      expect(Amigo.log_callback).to receive(:[]).
        with(nil, :warn, "high_latency_queues", {queues: {"x" => 11, "y" => 24}, depth: 5, duration: 20.5})
      instance.alert_log({"x" => 11, "y" => 24}, depth: 5, duration: 20.5)
    end
  end

  describe "alert_sentry" do
    before(:each) do
      require "sentry-ruby"
      @main_hub = Sentry.get_main_hub
      Sentry.init do |config|
        config.dsn = "http://public:secret@not-really-sentry.nope/someproject"
      end
    end

    after(:each) do
      Sentry.instance_variable_set(:@main_hub, nil)
    end

    it "calls Sentry" do
      expect(Sentry.get_current_client).to receive(:capture_event).
        with(
          have_attributes(message: "Some queues have a high latency: x, y"),
          have_attributes(extra: {high_latency_queues: {"x" => 11, "y" => 24}}),
          include(:message),
        )
      instance.alert_sentry({"x" => 11, "y" => 24})
    end
  end

  describe "alert callable" do
    it "calls the callable" do
      expect(Sidekiq::Queue).to receive(:all).and_return([fake_q("x", 1), fake_q("y", 20)])
      called_with = nil
      handler = proc do |arg|
        called_with = arg
      end
      o = instance(handlers: [handler])
      o.setup
      o.check
      expect(called_with).to eq({"y" => 20})
    end
  end

  describe "alert_restored_log" do
    after(:each) do
      Amigo.reset_logging
    end

    it "logs" do
      Amigo.structured_logging = true
      expect(Amigo.log_callback).to receive(:[]).
        with(nil, :info, "high_latency_queues_restored", {depth: 2, duration: 10.5})
      instance.alert_restored_log(depth: 2, duration: 10.5)
    end
  end
end
