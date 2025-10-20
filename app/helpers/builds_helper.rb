module BuildsHelper
  STATUS_STYLES = {
    "success" => "bg-emerald-100 text-emerald-800 border-emerald-200",
    "failure" => "bg-rose-100 text-rose-800 border-rose-200",
    "cancelled" => "bg-slate-200 text-slate-700 border-slate-300",
    "in_progress" => "bg-blue-100 text-blue-800 border-blue-200",
    "queued" => "bg-amber-100 text-amber-800 border-amber-200"
  }.freeze

  def status_badge(conclusion:, status: nil)
    value = conclusion || status
    return content_tag(:span, "Pending", class: badge_classes("queued")) unless value

    label = value.to_s.tr("_", " ").split.map(&:capitalize).join(" ")
    content_tag(:span, label, class: badge_classes(value))
  end

  def badge_classes(state)
    base = "inline-flex items-center rounded-full border px-2.5 py-1 text-xs font-medium"
    [base, STATUS_STYLES.fetch(state.to_s, "bg-slate-100 text-slate-700 border-slate-200")].join(" ")
  end

  def duration_label(seconds)
    return "–" unless seconds

    if seconds < 60
      "#{seconds.to_i}s"
    else
      minutes = seconds / 60
      remaining = seconds % 60
      remaining.zero? ? "#{minutes.to_i}m" : format("%dm %02ds", minutes, remaining)
    end
  end

  def formatted_timestamp(value)
    return "–" unless value

    value.in_time_zone.strftime("%Y-%m-%d %H:%M %Z")
  end

  def grouped_jobs(jobs)
    grouped = jobs.group_by { |job| job.name.split(" (").first }
    grouped.transform_values { |group| group.sort_by(&:name) }
           .sort_by { |group_name, _| group_name }
  end
end
