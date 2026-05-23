module SessionHelpers
  def sign_in_as(user)
    post "/test_sign_in", params: { user_id: user.id }
  end
end

RSpec.configure { |c| c.include SessionHelpers, type: :request }
