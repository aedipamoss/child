class BuildsController < ApplicationController
  before_action :ensure_run_id!, only: :show

  def new
  end

  def lookup
    run_id = params[:run_id].to_s.strip

    if run_id.blank?
      redirect_to new_build_path, alert: "Provide a workflow run ID to view its build dashboard."
    else
      redirect_to build_path(run_id)
    end
  end

  def show
    @repository = configured_repository
    child_workflow = configured_child_workflow
    @child_workflow = child_workflow

    fetcher = Github::BuildFetcher.new(
      run_id: params[:id],
      repository: @repository,
      child_workflow: child_workflow
    )

    @build = fetcher.call
  rescue Github::BuildFetcher::Error => e
    flash.now[:alert] = e.message
    render :new, status: :unprocessable_entity
  rescue Octokit::Unauthorized
    flash.now[:alert] = "The GitHub token provided does not have permission to view this workflow run."
    render :new, status: :unauthorized
  rescue Octokit::ClientError => e
    flash.now[:alert] = "GitHub API error: #{e.message}"
    render :new, status: :bad_gateway
  end

  private

  def ensure_run_id!
    return if params[:id].present?

    flash.now[:alert] = "Provide a workflow run ID to view its build dashboard."
    render :new, status: :unprocessable_entity
  end

  def configured_repository
    ENV.fetch("RAILS_CI_REPOSITORY") do
      Rails.application.credentials.dig(:github, :repository) ||
        raise(Github::BuildFetcher::Error, "Set RAILS_CI_REPOSITORY or configure credentials.github.repository")
    end
  end

  def configured_child_workflow
    ENV.fetch("RAILS_CI_CHILD_WORKFLOW") do
      Rails.application.credentials.dig(:github, :child_workflow) || "rails-build.yml"
    end
  end
end
