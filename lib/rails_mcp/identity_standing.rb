module RailsMcp
  # What the identity provider (Groundwork) says about one user right now.
  #
  # `status` is :active, :inactive or :unknown (the IdP couldn't be asked or
  # gave an answer we can't use). When the IdP also sends the user's
  # memberships, `accounts` is that list, each entry a Hash with "id", "name"
  # and "role", in the same shape as the userinfo `accounts`, and
  # `home_account_id` names the user's own workspace. `accounts` is nil when
  # the IdP sent no membership data (an older Groundwork), in which case only
  # the status is acted on.
  #
  # `mirror_account_column` is the local Account column holding the IdP's
  # account id, and `reason` a short note for logs when the status is
  # :unknown or :inactive ("HTTP 401", "Net::OpenTimeout").
  class IdentityStanding
    STATUSES = %i[active inactive unknown].freeze

    attr_reader :status, :accounts, :home_account_id, :mirror_account_column, :reason

    def initialize(status, accounts: nil, home_account_id: nil, mirror_account_column: :groundwork_account_id, reason: nil)
      raise ArgumentError, "unknown identity status #{status.inspect}" unless STATUSES.include?(status)

      @status = status
      @accounts = accounts&.map { |account| account.to_h.transform_keys(&:to_s) }
      @home_account_id = home_account_id.presence&.to_s
      @mirror_account_column = mirror_account_column
      @reason = reason
    end

    # Accepts what a host's `identity_status` hook returns: an
    # IdentityStanding, a bare :active / :inactive / :unknown (the pre-1.0
    # contract), or nil (no check configured, so nothing to enforce).
    def self.wrap(value)
      case value
      when nil then nil
      when IdentityStanding then value
      when Symbol, String then new(value.to_sym)
      else raise ArgumentError, "identity_status returned #{value.class}"
      end
    end

    def active?   = status == :active
    def inactive? = status == :inactive
    def unknown?  = status == :unknown

    def memberships? = !accounts.nil?

    def to_sym = status

    # Code written against the pre-1.0 contract compares the result of
    # `identity_status(user)` with a symbol; keep that working.
    def ==(other)
      other.is_a?(Symbol) ? status == other : super
    end
  end
end
