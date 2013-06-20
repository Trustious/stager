require 'fileutils'

class OperationsManager
  attr_reader :slots

  def initialize
    slot_port = Stager.settings.first_slot_port
    @slots = Stager.settings.slots.inject({}) do |hash, slot_name|
      hash[slot_name] = ActiveSlot.new(name: slot_name, port: slot_port)
      slot_port += 1
      hash
    end

    @slots_info_ts = Time.now - 42
    slots_info
  end

  def stage(slot_name, fork_name, branch_name)
    #FIXME can't stage multiple branches from same repo using current method :/
    if @slots.include?(slot_name)
      slot = @slots[slot_name]
      # ensure slot is in the database
      slot.save

      if slot.job_id != ''
        container = SidekiqStatus::Container.load(slot.job_id)
        container.request_kill
      end

      jid = OperationsManagerWorker.perform_async(slot_name, fork_name, branch_name)
      if jid
        slot.job_id = jid
        slot.save
        return true
      end
    end
    return false
  end

  def slots_info
    return @slots_info if (Time.now - @slots_info_ts) < 1.5
    @slots_info_ts = Time.now

    ActiveSlot.all.each do |active|
      next if !@slots.include?(active.name)
      @slots[active.name] = active
    end

    @slots_info = @slots.collect do |slot_name, slot|
      attrs = slot.attributes
      attrs.delete :app_pid
      attrs.delete :job_id

      if slot.job_id != ''
        container = SidekiqStatus::Container.load(slot.job_id)
        attrs[:status] = container.message if container.status != 'failed'
        attrs[:status] = container.status if attrs[:status].nil? or attrs[:status].empty?
      elsif slot.app_pid != -1
        attrs[:status] = 'Live'
      else
        attrs[:status] = 'Idle'
      end
      attrs
    end
  end

  def self.kill_process(pid)
    begin
      # kill it till it's dead
      10.times do
        Process.kill 'TERM', pid.to_i
        sleep 0.5
      end
      Process.kill 'KILL', pid.to_i
    rescue Errno::ESRCH
    end
  end
end

class OperationsManagerWorker
  include SidekiqStatus::Worker
  sidekiq_options retry: false

  def initialize
    @app_dir = ''
    @app_env = {}
  end

  def kill_app(pid)
    OperationsManager.kill_process pid
    spawn_and_wait './script/delayed_job stop'
  end

  def spawn_and_wait command
    pid = Process.spawn @app_env, command, chdir: @app_dir
    File.write(@cur_process_pid_file, pid) if @cur_process_pid_file
    Process.wait pid
    if $?.exitstatus == 0
      pid
    else
      -1
    end
  end

  def read_pid file
    File.read(file).to_i
  end

  def perform(slot_name, fork_name, branch_name)
    # HORRENDOUS HACK to avoid sqlite database locks
    # FIXME FIXME FIXME
    sleep 1
    # /FIXME
    slot = ActiveSlot.get(slot_name)

    self.total = 7

    at(1, 'Killing any running server')
    # kill any app we know is taking up this slot
    if slot.app_pid != -1 and !slot.current_fork.nil?
      @app_dir = RepoManager.repo_dir(slot.current_fork)
      kill_app slot.app_pid
      slot.app_pid = -1
    end

    slot.current_fork = fork_name
    slot.current_branch = branch_name
    slot.save

    @app_dir = RepoManager.repo_dir slot.current_fork

    # FIXME what if the branch to stage is already staged in another slot

    at(3, 'Updating repository')
    RepoManager.prepare_branch(slot.current_fork, slot.current_branch)

    Bundler.with_clean_env do
      @cur_process_pid_file = File.join(@app_dir, Stager.settings.staging_process_pid)
      server_pid_file = File.join(@app_dir, Stager.settings.server_pid)

      # ensure the existance of the pids dir
      FileUtils.mkdir_p(File.dirname(@cur_process_pid_file))
      FileUtils.mkdir_p(File.dirname(server_pid_file))

      # stop any staging process currently running on this app
      at(2, 'Killing old staging activity')
      begin
        pid = read_pid(@cur_process_pid_file)
        OperationsManager.kill_process pid
      rescue
      end

      # kill the current app if it is running and we don't know
      if File.exists?(server_pid_file)
        pid = read_pid(server_pid_file)
        kill_app pid
      end

      @app_env['RAILS_ENV'] = 'staging'
      @app_env['STAGING_HOST'] = "#{Stager.settings.host}:#{slot.port}"

      at(4, 'Creating Gem Bundle')
      spawn_and_wait 'bundle install'

      at(5, 'Precompiling Assets')
      if spawn_and_wait('bundle exec rake assets:precompile') < 0
        raise 'Failed to precompile assets'
      end

      at(6, 'Starting app server')
      pid = spawn_and_wait("bundle exec rails server -p #{slot[:port]} -d")
      if pid > 0
        slot.app_pid = pid
        slot.save
      else
        raise 'Failed to start the application'
      end

      at(7, 'Starting delayed_job worker')
      if spawn_and_wait('./script/delayed_job start') < 0
        raise 'Failed to start delayed_job worker'
      end
    end
  end
end
