module ApplicationHelper
  def clip_timestamp(milliseconds)
    total_seconds = milliseconds.to_i / 1000
    format("%d:%02d", total_seconds / 60, total_seconds % 60)
  end

  def score_percent(value)
    number = value.to_f
    number == number.round ? number.round.to_s : format("%.2f", number)
  end
end
