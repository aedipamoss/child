module Github
  class BuildFetcher
    class Error < StandardError; end

    require "time"

    Run = Struct.new(
      :id,
      :name,
      :status,
      :conclusion,
      :html_url,
      :run_attempt,
      :head_sha,
      :created_at,
      :updated_at,
      keyword_init: true
    )

    Job = Struct.new(
      :id,
      :name,
      :status,
      :conclusion,
      :html_url,
      :started_at,
      :completed_at,
      :duration_seconds,
      keyword_init: true
    )

    Build = Struct.new(
      :parent_run,
      :parent_jobs,
      :child_run,
      :child_jobs,
      keyword_init: true
    )

    def initialize(run_id:, repository:, child_workflow:, client: default_client)
      @run_id = run_id.to_i
      @repository = repository
      @child_workflow = child_workflow
      @client = client
    end

    def call
      parent_run_resource = client.workflow_run(repository, run_id)
      parent_run = build_run(parent_run_resource)
      child_run_resource = locate_child_run(parent_run)
      child_run = child_run_resource && build_run(child_run_resource)

      Build.new(
        parent_run: parent_run,
        parent_jobs: fetch_jobs(parent_run_resource),
        child_run: child_run,
        child_jobs: child_run_resource ? fetch_jobs(child_run_resource) : []
      )
    rescue Octokit::NotFound
      raise Error, "Workflow run #{run_id} was not found in #{repository}."
    end

    private

    attr_reader :run_id, :repository, :child_workflow, :client

    def default_client
      client = Octokit::Client.new(access_token: github_token)
      client.auto_paginate = true
      client
    end

    def github_token
      ENV.fetch("GITHUB_TOKEN") do
        credentials_token = Rails.application.credentials.dig(:github, :token)
        return credentials_token if credentials_token.present?

        raise Error, "A GitHub access token is required. Set the GITHUB_TOKEN environment variable or configure credentials."
      end
    end

    def build_run(resource)
      Run.new(
        id: resource.id,
        name: resource.display_title || resource.name,
        status: resource.status,
        conclusion: resource.conclusion,
        html_url: resource.html_url,
        run_attempt: resource.run_attempt,
        head_sha: resource.head_sha,
        created_at: timestamp(resource.created_at),
        updated_at: timestamp(resource.updated_at)
      )
    end

    def fetch_jobs(run_resource)
      attempt = run_resource.run_attempt || 1
      response = client.workflow_run_jobs(repository, run_resource.id, attempt: attempt)
      Array(response.jobs).map do |job|
        started_at = timestamp(job.started_at)
        completed_at = timestamp(job.completed_at)

        Job.new(
          id: job.id,
          name: job.name,
          status: job.status,
          conclusion: job.conclusion,
          html_url: job.html_url,
          started_at: started_at,
          completed_at: completed_at,
          duration_seconds: started_at && completed_at ? (completed_at - started_at).round : nil
        )
      end
    end

    def locate_child_run(parent_run)
      options = { event: "workflow_dispatch", per_page: 100 }
      options[:head_sha] = parent_run.head_sha if parent_run.head_sha.present?

      runs = client.workflow_runs(repository, child_workflow, **options)
      Array(runs.workflow_runs).find do |run|
        run.display_title&.include?(parent_run.id.to_s)
      end
    end

    def timestamp(value)
      return unless value

      value.is_a?(Time) ? value : Time.parse(value.to_s)
    end
  end
end
