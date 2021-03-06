module ForemanMaintain
  # Class responsible for running the scenario
  class Runner
    attr_reader :reporter, :exit_code

    require 'foreman_maintain/runner/execution'
    require 'foreman_maintain/runner/stored_execution'
    def initialize(reporter, scenarios, options = {})
      options.validate_options!(:assumeyes, :whitelist, :force)
      @assumeyes = options.fetch(:assumeyes, false)
      @whitelist = options.fetch(:whitelist, [])
      @force = options.fetch(:force, false)
      @reporter = reporter
      @scenarios = Array(scenarios)
      @quit = false
      @last_scenario = nil
      @exit_code = 0
    end

    def quit?
      @quit
    end

    def assumeyes?
      @assumeyes
    end

    def run
      @scenarios.each do |scenario|
        run_scenario(scenario)
        break if @quit
      end
    end

    # rubocop:disable Metrics/CyclomaticComplexity
    def run_scenario(scenario, confirm = true)
      return if scenario.steps.empty?
      raise 'The runner is already in quit state' if quit?

      if confirm
        confirm_scenario(scenario)
        return if quit?
      end

      execute_scenario_steps(scenario)
    ensure
      @last_scenario = scenario unless scenario.steps.empty?
      @exit_code = 1 if scenario.failed?
    end
    # rubocop:enable Metrics/CyclomaticComplexity

    def whitelisted_step?(step)
      @whitelist.include?(step.label_dashed.to_s)
    end

    def confirm_scenario(scenario)
      return unless @last_scenario
      decision = if @last_scenario.steps_with_error(:whitelisted => false).any?
                   :quit
                 elsif @last_scenario.steps_with_warning(:whitelisted => false).any?
                   reporter.ask_decision("Continue with [#{scenario.description}]")
                 end

      ask_to_quit if [:quit, :no].include?(decision)
      decision
    end

    def ask_to_quit(exit_code = 1)
      @quit = true
      @exit_code = exit_code
    end

    def add_steps(*steps)
      # we we add the steps at the beginning, but still keeping the
      # order of steps passed in the arguments
      steps.reverse.each do |step|
        @steps_to_run.unshift(step)
      end
    end

    def storage
      ForemanMaintain.storage(:default)
    end

    private

    def execute_scenario_steps(scenario)
      scenario.before_scenarios.flatten.each { |before_scenario| run_scenario(before_scenario) }
      return if quit? # the before scenarios caused the stop of the execution
      @reporter.before_scenario_starts(scenario)
      run_steps(scenario, scenario.steps)
      @reporter.after_scenario_finishes(scenario)
    end

    def run_steps(scenario, steps)
      @steps_to_run = ForemanMaintain::DependencyGraph.sort(steps)
      while !@quit && !@steps_to_run.empty?
        execution = run_step(@steps_to_run.shift)
        post_step_decisions(scenario, execution)
      end
    end

    def run_step(step)
      @reporter.puts('Rerunning the check after fix procedure') if rerun_check?(step)
      execution = Execution.new(step, @reporter,
                                :whitelisted => whitelisted_step?(step),
                                :storage => storage,
                                :force => @force)
      execution.run
      execution
    ensure
      storage.save
    end

    def post_step_decisions(scenario, execution)
      step = execution.step
      next_steps_decision = ask_about_offered_steps(step)
      if next_steps_decision != :yes &&
         execution.fail? && !execution.whitelisted? &&
         scenario.run_strategy == :fail_fast
        ask_to_quit
      end
    end

    # rubocop:disable  Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity
    def ask_about_offered_steps(step)
      if assumeyes? && rerun_check?(step)
        @reporter.puts 'Check still failing after attempt to fix. Skipping'
        return :no
      end
      if step.next_steps && !step.next_steps.empty?
        @last_decision_step = step
        steps = step.next_steps.map(&:ensure_instance)
        decision = @reporter.on_next_steps(steps)
        case decision
        when :quit
          ask_to_quit
        when Executable
          chosen_steps = [decision]
          chosen_steps << step if step.is_a?(Check)
          add_steps(*chosen_steps)
          :yes
        end
      end
    end
    # rubocop:enable  Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity

    def rerun_check?(step)
      @last_decision_step == step
    end
  end
end
