# Preview all emails at http://localhost:3000/rails/mailers/admin_mailer
class AdminMailerPreview < ActionMailer::Preview

  # Preview this email at
  # http://localhost:3000/rails/mailers/admin_mailer/booking_overdue
  def booking_overdue
    AdminMailer.booking_overdue
  end
  # Preview this email at
  # http://localhost:3000/rails/mailers/admin_mailer/payment_reported
  def payment_reported
    AdminMailer.payment_reported
  end
end
