# frozen_string_literal: true

# Use this hook to configure devise mailer, warden hooks and so forth.
# Many of these configuration options can be set straight in your model.
Devise.setup do |config|
  # The secret key used by Devise. Devise uses this key to generate
  # random tokens. Changing this key will render invalid all existing
  # confirmation, reset password and unlock tokens in the database.
  # Devise will use the `secret_key_base` as its `secret_key`
  # by default. You can change it below and use your own secret key.
  # config.secret_key = 'your-secret-key'

  # ==> Controller configuration
  # Configure the parent class to the devise controllers.
  # config.parent_controller = 'DeviseController'

  # ==> Mailer Configuration
  # Configure the e-mail address which will be shown in Devise::Mailer,
  # note that it will be overwritten if you use your own mailer class
  # with default "from" parameter.
  config.mailer_sender = 'noreply@fintrack.com'

  # Configure the class responsible to send e-mails.
  # config.mailer = 'Devise::Mailer'

  # Configure the parent class responsible to send e-mails.
  # config.parent_mailer = 'ActionMailer::Base'

  # ==> ORM configuration
  # Load and configure the ORM. Supports :active_record (default) and
  # :mongoid (bson_ext recommended) by default. Other ORMs may be
  # available as additional gems.
  require 'devise/orm/active_record'

  # ==> Configuration for any authentication mechanism
  # Configure which keys are used when authenticating a user. The default is
  # just :email. You can configure it to use [:username, :subdomain], so for
  # authenticating a user, both parameters are required. Remember that those
  # parameters are used only when authenticating and not when retrieving from
  # session. If you need permissions, you should implement that in a before filter.
  # You can also supply a hash where the value is a boolean determining whether
  # or not authentication should be case insensitive.
  # Default: :email
  #
  # Additional registerable should use other authentication strategies,
  # such as :twitter_oauth. This will allow you to use OAuth authentication
  # via twitter.
  config.authentication_keys = [:email]

  # Configure parameters from the request object used for authentication. Each entry
  # given should be a request method and it will automatically be passed to the
  # find_for_authentication method and considered in your model lookup. For instance,
  # if you set :request_keys to [:subdomain], :subdomain will be used on authentication.
  # The same considerations mentioned for authentication_keys also apply to request_keys.
  # config.request_keys = []

  # Configure which authentication strategy you want to use.
  # List of strategies: :database_authenticatable, :token_authenticatable,
  # :omniauthable, :rememberable, :confirmable, :lockable, :timeoutable, :activatable,
  # :recoverable, :registerable, :validatable, :trackable, :jwt_authenticatable
  # Devise JWT will be used as the default strategy when jwt_authenticatable is included

  # ==> Configuration for :database_authenticatable
  # For bcrypt, this is the cost for hashing the password and defaults to 12. If
  # using other algorithms, it is set to 4. In smaller production applications, it
  # is acceptable to use a lower value to save computation time.
  config.stretches = Rails.env.test? ? 1 : 12

  # Set up a pepper to generate the hashed password.
  # config.pepper = 'your-pepper'

  # Send a notification to the original email when the user's email is changed.
  # config.send_email_changed_notification = false

  # Send a notification email when the user's password is changed.
  # config.send_password_change_notification = false

  # ==> Configuration for :confirmable
  # A period that the user is allowed to access the account before their
  # email address is confirmed. The default is nil, which means that
  # confirmation is not required.
  # config.allow_unconfirmed_access_for = 2.days

  # A period that the user is allowed to confirm their account via a link in the
  # email. The default is nil, which means that confirmation is not required.
  # config.confirm_within = 3.days

  # If true, requires any email changes to be confirmed (exactly the same way as
  # initial account confirmation) to be applied. Requires send_email_changed_notification
  # to be set to true.
  # config.reconfirmable = true

  # ==> Configuration for :rememberable
  # The time the user will be remembered without asking for credentials again.
  # config.remember_for = 2.weeks

  # Invalidates all the remember me tokens when the user signs out.
  # config.expire_all_remember_me_on_sign_out = true

  # ==> Configuration for :validatable
  # Range for password length.
  config.password_length = 6..128

  # Email regex used to validate email format. Change this if you want to allow
  # more or less restrictive email formats.
  config.email_regexp = /\A[^@\s]+@[^@\s]+\z/

  # ==> Configuration for :recoverable
  #
  # Determines the time limit for the validity of the reset password token.
  # The default is 6 hours.
  config.reset_password_within = 6.hours

  # When set to false, does not sign a user in automatically after their password is
  # reset. Defaults to true, so a user is signed in after changing their password.
  # config.sign_in_after_reset_password = true

  # ==> Configuration for :lockable
  # Defines which key will be used when locking and unlocking an account
  # config.unlock_keys = [:email]

  # Defines which strategy will be used to unlock an account.
  # :email = Sends an unlock link to the user email
  # :time  = Re-enables login after a certain amount of time (see :unlock_in below)
  # :both  = Enables both strategies
  # config.unlock_strategy = :both

  # Number of authentication tries before locking an account if lock_strategy
  # is failed attempts.
  # config.unlock_in = 1.hour

  # Warn on the last attempt before the account is locked.
  # config.last_attempt_warning = true

  # ==> Navigation configuration
  # Lists the formats that should be treated as navigational. (Default: [:html])
  # config.navigational_formats = []

  # The default HTTP method used to sign users in and out. The default is :post.
  # config.sign_in_out_method = :post

  # ==> OmniAuth
  # Add a new OmniAuth provider. Check the wiki for more information on setting
  # up on your models and hooks.
  # config.omniauth :github, 'APP_ID', 'APP_SECRET', scope: 'user,public_repo'

  # ==> Warden configuration
  # If you want to use other strategies, that are not supported by Devise, or
  # change the failure app, you can configure them inside the config.warden block.
  #
  # config.warden do |manager|
  #   manager.intercept_401 = false
  #   manager.default_strategies(scope: :user).unshift :some_external_strategy
  # end

  # ==> Mountable engine configurations
  # When using Devise inside an engine, it's supposed to be mounted in the routes.
  # When using a namespaced engine, you can use the :scope option to set the namespace.
  # config.router_name = :my_engine

  # ==> Turbolinks configuration
  # If your app is using Turbolinks, Turbolinks::Controller will be included to make
  # navigation faster. Default is true.
  # config.turbolinks = false

  # ==> Configuration for :registerable
  # When set to false, does not sign a user in automatically after their password is
  # registered. Defaults to true, so a user is signed in after registration.
  # config.sign_in_after_change_password = true
end
