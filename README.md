# Rails CI build dashboard

This application provides a focused view of the Rails build pipeline. Instead of
digging through dozens of GitHub Actions jobs, you can supply the workflow run
ID from the proof-of-concept dispatcher and see a grouped summary of the parent
workflow and the dispatched Rails build.

## Getting started

```bash
bundle install
bin/rails db:prepare # No-op, but keeps Rails happy
bin/dev
```

Visit <http://localhost:3000> and enter the workflow run ID that was produced by
the `Proof of Concept Pipeline` workflow.

## Configuration

The dashboard needs a GitHub token with permission to read Actions runs for the
target repository. You can provide settings through environment variables or the
Rails credentials file:

| Setting | Description | Default |
| --- | --- | --- |
| `GITHUB_TOKEN` | Token used when calling the GitHub API. | Required |
| `RAILS_CI_REPOSITORY` | The `<owner>/<repo>` slug that hosts the workflows. | Credential `github.repository` |
| `RAILS_CI_CHILD_WORKFLOW` | Workflow file name for the child Rails build. | `rails-build.yml` |

To configure via credentials:

```bash
bin/rails credentials:edit
```

```yml
github:
  token: ghp_example
  repository: rails/rails
  child_workflow: rails-build.yml
```

## How it works

* The parent workflow run is fetched via `GET /actions/runs/:id` and displayed
  with its job list.
* The associated child run is resolved by matching the run name, which includes
  the parent workflow ID, within the `rails-build.yml` workflow history.
* Jobs from the child workflow are grouped by framework prefix (for example,
  `Action Mailer`, `Active Record`, and so on) so you can quickly assess the
  state of each subsystem.

If a child workflow cannot be found yet, the dashboard will continue to display
the parent status until GitHub reports the downstream run.
