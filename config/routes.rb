require_relative "../app/constraints/sudo_constraint"

Rails.application.routes.draw do
  # Any 2-letter code matches at the routing layer, rather than being compiled
  # from I18n.available_locales, which would need a restart every time a sudo
  # release added one. ApplicationController#verify_locale_is_released is the
  # actual gate, checked per request against LANGUAGES plus
  # Language.released_codes; an unreleased or made-up code 404s there.
  scope '(:locale)', locale: /[a-z]{2}/ do
    

    # Controllers live in app/controllers/acc/ but "/acc" stays out of the URL.
    # This scope is what keeps the paths right until the namespace itself is
    # dropped.

    get :dashboard, to: "dashboard#index"

    # Both are checkpoints for an already signed-in admin, merged into one
    # controller (GatesController). Helper names and paths were kept identical
    # to when they were two controllers, so nothing that calls them needed to
    # change.
    get  'otp',         to: 'gates#otp_show',    as: :otp
    post 'otp/verify',  to: 'gates#otp_verify',  as: :verify_otp
    post 'otp/confirm', to: 'gates#otp_confirm', as: :confirm_otp

    get  'terms',       to: 'gates#terms_show',  as: :terms
    post 'terms/agree', to: 'gates#terms_agree', as: :agree_terms

    # A draft coadmin's forced first-login flow — confirm email, via the
    # existing verify_email token link, then set a real password, before
    # reaching anything else. See Admin#draft?.
    get   'claim',        to: 'gates#claim_show',   as: :claim
    patch 'claim',        to: 'gates#claim_update'
    post  'claim/resend', to: 'gates#claim_resend', as: :resend_claim

    resources :admin_entities, only: [:destroy]

    resources :accounts do
      collection { get :parents_for_type }
      member do
        patch :quick_map_tax
        patch :save_deduction_percentage
        get :ledger
        get :balance_at
        # deposits
        get :new_deposit
        post :create_deposit
        get :edit_deposit
        patch :update_deposit
        get :copy_deposit
        # withdrawals
        get :new_withdrawal
        post :create_withdrawal
        get :edit_withdrawal
        patch :update_withdrawal
        get :copy_withdrawal
        # transfers
        get :new_transfer
        post :create_transfer
        get :edit_transfer
        patch :update_transfer
        get :copy_transfer
      end
    end
    resources :exchange_rates do
      collection do
        get  :lookup
        post :fetch_rates
      end
    end

    # The currencies this installation supports. DATA, not code. No :show — a
    # currency is a code and a symbol, and the index already shows both.
    #
    # Deactivation is NOT a form field: it means "this currency has ceased to
    # exist", it is global, and it is sudo's.
    resources :currencies, except: [ :show ] do
      member do
        patch :deactivate
        patch :reactivate
      end
    end

    # Taxpayers belong to the ADMIN, not to an entity — one taxpayer may keep
    # several sets of books, and the point is that they authorise once and pick
    # the same one for each. Deliberately NOT "registrations": the main site
    # already has that controller, and one body class would have picked up the
    # other's CSS.
    resources :taxpayers, except: [ :show ] do
      collection do
        # The tax setup page's modal: choose one of this authority's
        # taxpayers, or open the form to add one.
        get :choose
      end
    end

    resources :entities do
      resources :report_groups, only: [:create]
      collection do
        # ONE callback endpoint for every authority — the connector is read from
        # the session, not from the path. Which URI is SENT comes from
        # Filing::Base.registered_callback_path, because a redirect URI is
        # registered with the authority and must match character for character.
        get :filing_callback, to: 'filing#callback'
      end
      member do
        get    :edit_tax
        patch  :update_tax
        # The picker for a just-ticked scheme, fetched as a partial.
        get    :filing_fields
        delete :leave           # an admin unlinks themselves from this entity
        # Generic filing routes — connector or scheme param selects the service
        get    'filing/connect',    to: 'filing#connect',    as: :filing_connect
        get    'filing/periods',    to: 'filing#periods',    as: :filing_periods
        post   'filing/submit',     to: 'filing#submit',     as: :filing_submit
        get    'filing/view',       to: 'filing#view',       as: :filing_view
        # Creates a report over the period the authority asked for — POST,
        # because it writes. As a GET, reports appeared that nobody had asked
        # for.
        post   'filing/report',     to: 'filing#report',     as: :filing_report
        delete 'filing/disconnect', to: 'filing#disconnect', as: :filing_disconnect
      end
    end

    resources :report_groups, only: [:show, :edit, :update, :destroy] do
      member { patch :update_accounts }
      resources :reports, only: [:new, :create]
    end
    resources :reports, only: [:index, :show, :edit, :update, :destroy] do
      member do
        post :tax_export
        # *key, not :key: a plain segment excludes dots by default, reserved for
        # format-parsing, even with format: false — and the filename carries
        # ".csv", so it needs the wildcard, same as the archive routes below.
        get "tax_export_backup/*key", to: "reports#download_tax_export_backup",
                                       as: :download_tax_export_backup, format: false
      end
      collection do
        get :trial_balance
        get :profit_loss
        get :balance_sheet
        get :fx_variance
        get :new_year_end
        post :create_year_end
        post :change_year_end
        # On-demand books archive: entity_id names the entity or family, and the
        # range is always from the beginning through today, server-side, never
        # trusted from the client. Download and destroy take the full storage
        # key as a wildcard segment because it contains slashes.
        post :create_archive
        get "archive/*key", to: "reports#download_archive", as: :download_archive, format: false
        delete "archive/*key", to: "reports#destroy_archive", as: :destroy_archive, format: false
      end
    end

    resources :journal_entries do
      member do
        patch :post
        patch :unpost
        get :duplicate
      end
      collection do
        get :cross_entity_rows # renders a linked entry's posting rows for the modal
      end
    end

    resources :receipts do
      member do
        post :link
        post :unlink
        delete :delete_own
        get :download
      end
      collection do
        get :upload_standalone
        get :for_posting, path: "for_posting/:posting_id"
        get :unlinked
        post :share_receive
        # Bulk export: a zip of exactly the receipts ticked on the current index
        # page. POST, not GET — a page of ids in a query string is the kind of
        # URL that ends up truncated or logged.
        post :download_selected
      end
    end

  # Privacy policy + terms. Served by WelcomeController rather than by anything
  # behind a login — a tax authority's OAuth consent screen links here.
  get 'legal' => 'welcome#legal', as: :legal

  # The public demo. One path, two verbs: GET describes what you are walking
  # into, POST walks you in. Starting a session is never a GET.
  get  'demo' => 'welcome#demo',       as: :demo
  post 'demo' => 'welcome#demo_enter', as: :demo_enter

  # The manuals. Public like the legal notice above and rendered by the same
  # controller out of the same app/views/help folder, so they sit alongside it
  # at the top level and path, action and helper are all the same word.
  get "easy_manual", to: "welcome#easy_manual", as: :easy_manual
  get "pro_manual",  to: "welcome#pro_manual",  as: :pro_manual

    post 'contrast' => 'welcome#contrast', as: :contrast

    resource :session, only: [:new, :create, :destroy]
    get 'login', to: 'sessions#new', as: :login
    
    resources :passwords, param: :token
    get 'verify_email/:token', to: 'admins#verify_email', as: :verify_email
    resources :admins do
      member do
        patch :update_preferences
        post :resend_claim_email
      end
      collection do
        get :email_lookup
      end
    end

    # Sudo-only, on top of the shipped LANGUAGES — see Language and
    # LanguagesController for why this sits at a different bar than :currencies.
    resources :languages do
      member do
        patch :release
        patch :unrelease
      end
    end

    # Installation-level document uploads — sudo only, one POST replaces
    # whatever is already stored for that kind. No :id or :kind in the path; the
    # kind comes from the form itself.
    resources :documents, only: [:create]
    
  

      
          
    constraints(SudoConstraint.new) do
      mount MissionControl::Jobs::Engine => "/jobs"
    end
  
    # Define your application routes per the DSL in
    # https://guides.rubyonrails.org/routing.html
  
    # Reveal health status on /up that returns 200 if the app boots with no
    # exceptions, otherwise 500.
    # Can be used by load balancers and uptime monitors to verify that the app
    # is live.
    get "up" => "rails/health#show", as: :rails_health_check
  
    # Render dynamic PWA files from app/views/pwa/*
    get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
    get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
    
    # The public front page. Signing in lands on the dashboard, not here —
    # see SessionsController and Authentication#after_authentication_url.
    root "welcome#index"
     
  end

  # Fixed, locale-independent path required by RFC 9116. Rendered so it reads
  # the single CONTACT_EMAIL source of truth (see
  # config/initializers/contact.rb).
  get "/.well-known/security.txt" => "welcome#security_txt"
#  get "service-worker" => "pwa#service_worker", as: :pwa_service_worker
#  get "manifest" => "pwa#manifest", as: :pwa_manifest
end
