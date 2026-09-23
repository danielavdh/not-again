# frozen_string_literal: true

# Unhandled exceptions — the 500s — recorded as ErrorEvent rows, so the weekly
# report can say a page has been failing all week. Rails already reports them
# through Rails.error; this only subscribes.
#
# No Sentry or similar, deliberately: those ship the exception's context off the
# server, and here that context is somebody's books.
class ErrorEventSubscriber
  # handled: false is the unhandled ones — what a visitor saw as a 500. A
  # handled error was rescued by the code that raised it, which is the code
  # working, not failing.
  def report(error, handled:, severity:, context: {}, source: nil)
    return if handled

    ErrorEvent.record(
      error_class: error.class.name,
      source:      where_from(context),
      message:     error.message,
      path:        path_of(context),
      line:        app_line(error)
    )
  end

  private

  # "ReportsController#show", "TaxExportJob", or the reporting source Rails
  # gives when neither is in play (a middleware, say).
  def where_from(context)
    if (controller = context[:controller])
      "#{controller.class.name}##{controller.action_name}"
    elsif (job = context[:job])
      job.class.name
    else
      "(unknown)"
    end
  end

  # The path WITHOUT its query string: "/en/reports/41" says which page, while
  # the query string is where the content lives (a search term, a filter).
  def path_of(context)
    context[:controller]&.request&.path
  end

  # The first backtrace line inside this app — the answer to "where", where the
  # framework frames above it are noise.
  def app_line(error)
    root = Rails.root.to_s
    frame = error.backtrace&.find { |l| l.start_with?(root) && !l.include?("/vendor/") }
    frame&.delete_prefix("#{root}/")&.split(":in ")&.first
  end
end

Rails.error.subscribe(ErrorEventSubscriber.new)
