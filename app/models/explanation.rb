class Explanation < ApplicationRecord
  belongs_to :candidate_score

  validates :explanation_version, :summary, presence: true
  validates :strengths, :weaknesses, :quantitative_facts, array_payload: true
end
