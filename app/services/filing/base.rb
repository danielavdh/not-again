# frozen_string_literal: true

# ## Legal implications of adding a connector
#
# Data that would otherwise stay in the books gets sent to an outside authority.
# The /legal page needs to inform the user of this fact.
#########################################################################
### If you add a NEW connector, add the legal text at the top of its file, 
### add `filing.#{AUTHORITY_KEY}.legal_html` to config/locales/*.yml,
### and add the translations to the languages you show. 
### This adds the legal text for your new connector to the /legal page automatically.
### If you skip English: the page shows "translation missing: ..." instead of your paragraph
### If you skip another language: I18n falls back to English there.
### Example in hmrc_mtd.rb.
#########################################################################


module Filing
  # A filing connector submits a scheme's figures to a tax authority on the
  # user's behalf.
  #
  # Adding one: write app/services/filing/<connector>.rb subclassing Base and
  # implementing the methods below, then add the connector to CONNECTORS.
  #
  # The class name IS the connector's name: Filing::HmrcMtd ↔ hmrc_mtd. The only
  # other place that string appears is `connector:` in a scheme's catalogue
  # header, so nothing in the code can drift — only the YAML header has to
  # agree.
  class Base
    # Connectors that actually exist. A catalogue may name one in its
    # `connector:` header before anyone has built it — the header describes the
    # country's reality, this list describes ours, and keeping them separate is
    # what lets a country be added at tier 2 and gain submission later.
    #
    # Explicit rather than derived from `subclasses`: under autoloading, a class
    # nobody has referenced yet does not exist yet.
    CONNECTORS = %w[hmrc_mtd].freeze

    # An obligation is either still owed or already met, and every connector
    # says so in these words. The connector translates its authority's own
    # vocabulary at its own edge, so the shared views never test one authority's
    # letters — which would make a second connector translate into the first's
    # language before the page could read it.
    STATUS_OPEN      = :open
    STATUS_FULFILLED = :fulfilled

    # The identifier(s) this authority uses to know the TAXPAYER — not the
    # business. Declared by the connector because only it knows what its
    # authority asks for, and only it can be sure the value is usable: HMRC will
    # not match "ab 12 34 56 c".
    #
    # Labels and hints come from filing.<AUTHORITY_KEY>.<key>_label / _hint — by
    # authority, not by connector, because two services sharing a login also
    # share the taxpayer's number. A new authority adds its own keys and no view
    # changes.
    IDENTIFIERS = [].freeze

    # Which authority's credentials this connector uses — the key stored on
    # Taxpayer. Separate from the connector's own name because one authority can
    # run several services on ONE authorisation: HMRC's MTD and a future VAT
    # connector would share a login, so they share a taxpayer.
    AUTHORITY_KEY = nil

    attr_reader :entity, :scheme, :admin, :taxpayer

    # Who this connector files with — "HMRC", "ELSTER". Every user-facing string
    # on the filing path interpolates it, so no view or controller has to know
    # which authority it is talking to. Answered from the connector, not the
    # scheme, because the OAuth callback has no scheme.
    def authority
      TaxSchemeConfig.authority_for_connector(self.class.connector)
    end

    # `taxpayer` is passed for connect and disconnect, where there is no scheme
    # to reach one through — the OAuth callback returns knowing only which
    # connector sent it. Everywhere else it is nil and read from the tax report
    # group, which is the thing being filed.
    def initialize(entity:, scheme:, admin:, taxpayer: nil)
      @entity       = entity
      @scheme       = scheme
      @admin        = admin
      @taxpayer = taxpayer
    end

    # Returns the URL to redirect to for the authority's login page.
    def connect_url(callback_uri:, state:)
      raise NotImplementedError
    end

    # Exchanges the OAuth callback params for tokens; stores them on the
    # Taxpayer being connected.
    def handle_callback(params:, redirect_uri:)
      raise NotImplementedError
    end

    # Ends the permission on the taxpayer. The taxpayer's number stays —
    # it belongs to the person, not to the session.
    def disconnect
      raise NotImplementedError
    end

    # The businesses this authority holds for the taxpayer, keyed by OUR scheme
    # slug, each as the authority returned it. Used to OFFER a choice — nobody
    # can know their business identifier until the authority says it, so a free-
    # text box before connecting only invites a wrong value.
    #
    # Empty for an authority with no such concept, and empty rather than raising
    # when it cannot be reached: this is a setup page, not a submission.
    def businesses_by_scheme
      {}
    end

    # Where the taxpayer goes to correct the names the authority holds, when we
    # have refused to guess between them. Nil for an authority that names
    # nothing, or offers nowhere to fix it.
    def self.business_name_help_url
      nil
    end

    # The authority's own name for one business, as it returned it — the thing a
    # human picks by, so where it is missing or repeated, nobody can pick. Nil
    # for an authority whose businesses have no names.
    def self.business_name(_business)
      nil
    end

    # Schemes whose businesses cannot be told apart: more than one business, and
    # their names blank or repeated.
    #
    # We refuse rather than guess. Two businesses a person cannot distinguish is
    # a choice made by coin toss, and the cost of losing it is silent — each
    # update replaces the last one for that business, so figures filed against
    # the wrong trade are simply kept, with no error at either end. The names
    # are the authority's to fix, so the user is sent there.
    #
    # One business is never ambiguous, named or not. Compared on a squished,
    # case-folded name: "Plastering" and "plastering " are one trade to the eye,
    # and the eye is what this protects.
    def self.ambiguous_schemes(by_scheme)
      by_scheme.select { |_scheme, list|
        next false if list.size < 2
        names = list.map { |b| business_name(b).to_s.downcase.gsub(/\s+/, " ").strip }
        names.any?(&:empty?) || names.uniq.size < names.size
      }.keys
    end

    # Anything an authority requires to be gathered from the REQUEST rather than
    # from the books, done before a call goes out to it.
    #
    # HMRC is the live case and the reason this exists: it mandates "fraud
    # prevention" headers describing the browser and the connection, which can
    # only be read from the request that triggered the call. Nobody else asks
    # for them.
    #
    # A generic controller cannot know what an authority wants from a request;
    # only the connector can, so only the connector is asked. A no-op by
    # default, because most authorities want nothing.
    def self.prepare_request(request:, admin:, cookies:, session:)
      nil
    end

    # The path this connector's authority has been told to redirect back to
    # after login.
    #
    # A connector's own fact, not the app's: a redirect URI is REGISTERED with
    # the authority, and sending one that differs by a single character is
    # refused. So the default is the neutral endpoint, and a connector overrides
    # it only while its authority holds an older registration.
    #
    # One controller action serves them all regardless; the connector is read
    # from the session, never from the path.
    def self.registered_callback_path
      "/entities/filing_callback"
    end

    # The name of a browser-side collector this authority requires, or nil.
    #
    # The counterpart to .prepare_request: some of what HMRC demands can only be
    # read in the browser — screen size, timezone, a persistent device id — so a
    # script has to gather it before the request that needs it is made. Rendered
    # as a data attribute on the pages that lead to this authority, and
    # scripts/index.js starts the matching collector when it sees one.
    #
    # Never start it unconditionally: every admin, including one who files
    # nothing and one filing in Germany, would get a persistent device id in
    # localStorage and a fingerprint cookie for an authority they may never
    # touch.
    def self.browser_collector
      nil
    end

    # A partial the filing page renders for THIS authority, or nil.
    #
    # The filing page must never name an authority. Anything only one of them
    # shows — a required disclosure, their record of the business — lives in
    # app/views/filing/<connector>/ and is reached only through here. A new
    # authority adds its own directory and overrides this; no `if` in a template
    # learns a second name.
    def panel_partial
      nil
    end

    # The currency this scheme files in, declared in its catalogue header. The
    # user never picks it: a submission has one currency, and a tax report
    # totals into the same one so the two always agree.
    #
    # Here rather than on a connector for the same reason as panel_partial — the
    # shared filing views must not name an authority OR its money. Formatting
    # every amount as "GBP" in eleven places showed a German EÜR with euro
    # figures labelled £.
    #
    # No fallback currency. There is no honest generic default, so a scheme that
    # forgets to declare `currency:` renders with no symbol at all, which is the
    # right failure: a missing symbol is visible, a confidently wrong one is
    # not.
    def submission_currency
      TaxSchemeConfig.currency_for(scheme)
    end

    # Returns { obligations: Array, preview: Hash|nil, error: String|nil }
    def periods
      raise NotImplementedError
    end

    # Submits the period. Yields locals Hash to caller for HTML rendering,
    # stores the returned HTML, and sends the notification email.
    def submit(period_id:, view_url:, &renderer)
      raise NotImplementedError
    end

    # Returns stored HTML string for the given period_id, or raises.
    def view_html(period_id:)
      raise NotImplementedError
    end

    # [start_date, end_date] actually covered by a submission for this period —
    # not necessarily the obligation's own dates. Lets a report be opened over
    # exactly what was sent.
    def report_period(period_id)
      raise NotImplementedError
    end

    class << self
      # Is there a connector for this connector? The question every caller that
      # merely wants to OFFER submission should ask — a scheme whose catalogue
      # declares an authority we cannot yet reach must not grow a connect
      # button.
      def registered?(connector)
        CONNECTORS.include?(connector.to_s)
      end

      def for(connector, **kwargs)
        klass = connector_class(connector)
        raise ArgumentError, "Unknown connector: #{connector.inspect}" unless klass
        klass.new(**kwargs)
      end

      # Resolved against the enclosing MODULE, not against Base: connectors are
      # siblings of Base, not nested inside it, so const_get on Base would miss
      # them and quietly return nothing.
      #
      # `false` = do not search ancestors. Without it const_get falls back to
      # Object, so a connector of "string" would resolve to ::String.
      def connector_class(connector)
        return nil unless registered?(connector)
        Filing.const_get(connector.to_s.camelize, false)
      rescue NameError
        nil
      end

      # Authorities THIS INSTALL actually files with — derived from what its own
      # catalogue declares, not from which connector classes the shared codebase
      # carries. The two are different questions once this is open source: two
      # installs can run the same code and use different connectors, or none at
      # all.
      #
      # Anything that must not over-claim what an install does — the /legal page
      # is the reason this exists — asks this, never CONNECTORS.
      def authorities_in_use
        TaxSchemeConfig.all_schemes
                        .filter_map { |s| TaxSchemeConfig.connector_for(s) }
                        .filter_map { |c| connector_class(c)&.authority_key }
                        .uniq
      end

      # "hmrc_mtd" for Filing::HmrcMtd — see the note above the class.
      def connector
        name.demodulize.underscore
      end

      def authority_key
        self::AUTHORITY_KEY
      end

      # Every built connector that files with this authority. Several once one
      # authority has more than one service.
      def connectors_for_authority(key)
        CONNECTORS.filter_map { |c| connector_class(c) }
                  .select { |k| k.authority_key == key.to_s }
      end

      def identifiers
        self::IDENTIFIERS
      end

      # The union of what every connector at this authority needs to know
      # about the taxpayer. Two services sharing a login also share the number.
      def identifiers_for_authority(key)
        connectors_for_authority(key).flat_map(&:identifiers).uniq
      end

      def normalise_for_authority(key, identifier, value)
        connector = connectors_for_authority(key).first
        connector ? connector.normalise_identifier(identifier, value) : value.to_s.strip.presence
      end

      def valid_identifier_for_authority?(key, identifier, value)
        connector = connectors_for_authority(key).first
        connector ? connector.valid_identifier?(identifier, value) : true
      end

      # Put a value into the shape the authority will accept. Stripping is the
      # least any authority wants; connectors override for their own formats.
      def normalise_identifier(_key, value)
        value.to_s.strip.presence
      end

      # True unless a connector knows the format and says otherwise. An
      # authority we have not taught a shape to gets the benefit of the doubt:
      # it will reject what it does not like, and refusing a number we have no
      # rule for would only block the user from getting started.
      def valid_identifier?(_key, _value)
        true
      end
    end
  end
end
