module SessionHelpers
  def sign_in_as(user, signed_in_at: nil)
    params = { user_id: user.id }
    params[:signed_in_at] = signed_in_at.to_i if signed_in_at
    post "/test_sign_in", params: params
  end
end

RSpec.configure { |c| c.include SessionHelpers, type: :request }
