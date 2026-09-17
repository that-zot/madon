# frozen_string_literal: true

# madon Phase 0.5 — let OIDC users pick their own @-handle on first sign-in.
#
# The upstream Mastodon flow auto-creates a User+Account when an OIDC
# callback finds no Identity, deriving the public username from auth.uid.
# For madon, auth.uid is a vits.me SolidNumber — a private per-app
# pseudonymous ID that must never be exposed. And Mastodon usernames are
# immutable once an Account is created (no rename in Settings::Profiles,
# no tootctl command), so this has to be fixed AT signup, not after.
#
# Strategy: skip the auto-create, let the controller's existing redirect
# to /auth/sign_up fire, and pre-bind the registration form to the OIDC
# session via Devise's documented User.new_with_session hook. The user
# fills in only the username field; an after_create callback links the
# new User to the OIDC sub via Identity.

Rails.application.config.to_prepare do
  # 1. Skip create_for_auth on OIDC sign-in. Auth::OmniauthCallbacksController
  # checks `@user.persisted?` (controller line 12), so we MUST return a
  # non-nil User; an unpersisted User.new makes the `else` branch fire,
  # which stores the auth hash in session["devise.<provider>_data"] and
  # redirects to new_user_registration_url.
  User::Omniauthable::ClassMethods.module_eval do
    def find_for_omniauth(auth, signed_in_resource = nil)
      auth.uid = (auth.uid[0][:uid] || auth.uid[0][:user]) if auth.uid.is_a?(Hashie::Array)
      identity = Identity.find_for_omniauth(auth)

      user   = signed_in_resource || identity.user
      user ||= reattach_for_auth(auth)
      user ||= User.new # unpersisted — controller will redirect to /auth/sign_up

      if identity.user.nil? && user.persisted?
        identity.user = user
        identity.save!
      end

      user
    end
  end

  # 2. Make the registration form pre-populate from the OmniAuth session.
  # Devise's stock new_with_session (devise-4.9.4 registerable.rb:21–23)
  # discards `session` and just calls `new(params)`. We replace it with one
  # that reads session["devise.<provider>_data"] and pre-fills email /
  # external / agreement, while leaving username blank for the user to fill.
  User.singleton_class.prepend(Module.new do
    def new_with_session(params, session)
      auth_keys = Devise.omniauth_providers.map { |p| "devise.#{p}_data" }
      auth_data = auth_keys.map { |k| session[k] }.compact.first
      return super unless auth_data

      auth = OmniAuth::AuthHash.new(auth_data)
      email, email_is_verified = send(:email_from_auth, auth)
      base = send(:user_params_from_auth, email, auth)
      # When vits.me ships no email claim (always, today), upstream
      # user_params_from_auth falls back to a placeholder built from auth.uid (the
      # SolidNumber) + provider — e.g. "change@me-<SolidNumber>-openid_connect.com" —
      # which parks the private SolidNumber in users.email (admin UI, mailer/Sidekiq
      # logs). Re-roll it as an opaque, non-deliverable placeholder carrying no
      # SolidNumber, keeping the upstream TEMP_EMAIL_PREFIX so Mastodon still treats
      # it as a temporary address (TEMP_EMAIL_REGEX / User#email_present?).
      base[:email] = "#{User::Omniauthable::TEMP_EMAIL_PREFIX}-#{SecureRandom.hex(8)}.invalid" if email.blank?
      # Don't seed the form's username field with the SolidNumber-derived value.
      base[:account_attributes][:username] = ''
      base[:account_attributes][:display_name] = ''

      merged = base.deep_merge(params || {})
      user = new(merged)
      user.instance_variable_set(:@pending_oidc_auth, auth)
      # Mirror create_for_auth: skip email confirmation when OIDC asserts the
      # email is verified (OIDC_SECURITY_ASSUME_EMAIL_IS_VERIFIED=true). Without
      # this the user is routed to "check your inbox" with the placeholder
      # change@me-… email after submitting the registration form.
      user.skip_confirmation! if email_is_verified
      user
    end
  end)

  # 2b. Ensure User#external? is public — our registration view calls
  # resource.external? to decide whether to render the email/password fields.
  # Mastodon ≤4.4 defined external? as an explicit *private* method, so we had
  # to flip it public. Mastodon 4.5+ replaced it with `attribute :external,
  # :boolean`, whose generated predicate is already public — and isn't even
  # materialized yet when this initializer runs, so a blind `public :external?`
  # raises NameError. Only flip visibility when upstream still ships it private.
  User.class_eval { public :external? } if User.private_method_defined?(:external?)

  # 3. After save, link the new User to the OIDC sub via Identity. The
  # belongs_to :user is required, so we can't do find_or_create_by without
  # passing user; we look up an existing row first (a previous failed
  # registration attempt for the same sub may have left one) and reuse it.
  User.set_callback(:create, :after, :build_pending_identity_for_madon)
  User.class_eval do
    def build_pending_identity_for_madon
      auth = instance_variable_get(:@pending_oidc_auth)
      return unless auth

      identity = Identity.find_by(uid: auth.uid, provider: auth.provider)
      if identity
        identity.update!(user: self)
      else
        Identity.create!(user: self, uid: auth.uid, provider: auth.provider)
      end
    end
  end

  # 3b. Slim the data stored in session on the not-persisted branch.
  # Upstream stashes the entire request.env['omniauth.auth'] (id_token,
  # raw_info, credentials, …) which blows past Mastodon's 4KB cookie
  # session and triggers ActionDispatch::Cookies::CookieOverflow. We only
  # need provider + uid (+ a few info fields if vits.me ever ships them).
  Auth::OmniauthCallbacksController.prepend(Module.new do
    Devise.omniauth_providers.each do |provider|
      define_method(provider) do
        @provider = provider
        @user = User.find_for_omniauth(request.env['omniauth.auth'], current_user)

        if @user.persisted?
          record_login_activity
          sign_in_and_redirect @user, event: :authentication
          set_flash_message(:notice, :success, kind: label_for_provider) if is_navigational_format?
        else
          auth = request.env['omniauth.auth']
          info = auth.info ? auth.info.to_h.slice('email', 'name', 'full_name', 'first_name', 'last_name').compact : {}
          session["devise.#{provider}_data"] = {
            'provider' => auth.provider,
            'uid'      => auth.uid,
            'info'     => info,
          }
          redirect_to new_user_registration_url
        end
      rescue ActiveRecord::RecordInvalid
        flash[:alert] = I18n.t('devise.failure.omniauth_user_creation_failure') if is_navigational_format?
        redirect_to new_user_session_url
      end
    end
  end)

  # 3c. Override after_sign_out_path_for. Upstream
  # ApplicationController#after_sign_out_path_for (line 100–106) redirects
  # to '/auth/auth/openid_connect/logout' when OMNIAUTH_ONLY+OIDC is on,
  # assuming an RP-initiated logout endpoint exists. vits.me's OIDC
  # discovery doc has no end_session_endpoint, so that path 404s and
  # Mastodon shows an error page on sign-out. Send users to the sign-in
  # page instead.
  ApplicationController.prepend(Module.new do
    def after_sign_out_path_for(_resource_or_scope)
      new_user_session_path
    end
  end)

  # 4. Allow registration when the visitor has a pending OmniAuth session,
  # even though OMNIAUTH_ONLY=true normally blocks /auth/sign_up via
  # RegistrationHelper#allowed_registration?. The session check stands in
  # for the existing invite-token bypass (`invite&.valid_for_use?`).
  RegistrationHelper.module_eval do
    alias_method :_madon_orig_allowed_registration?, :allowed_registration?

    def allowed_registration?(remote_ip, invite)
      auth_keys = Devise.omniauth_providers.map { |p| "devise.#{p}_data" }
      return true if auth_keys.any? { |k| session[k].present? }

      _madon_orig_allowed_registration?(remote_ip, invite)
    end
  end
end

# 5. Remove `invite_users` from the default user role. We use the standard
# Mastodon registration form as the OIDC handle-pick flow, but Mastodon's
# OOB default lets every regular user generate invite links from /invites.
# Those links are dead-ends here (OMNIAUTH_ONLY blocks the form for
# non-OIDC visitors and they get a silent 302 to /), so showing the
# "Generate invite" UI only confuses people. Admins keep `manage_invites`
# (a separate flag) and can still see the admin invites view if needed.
Rails.application.config.after_initialize do
  if ActiveRecord::Base.connection.data_source_exists?('user_roles')
    role = UserRole.everyone
    if role.permissions.anybits?(UserRole::FLAGS[:invite_users])
      role.update_column(:permissions, role.permissions & ~UserRole::FLAGS[:invite_users])
      Rails.logger.info("madon: stripped invite_users from UserRole.everyone")
    end
  end
end
