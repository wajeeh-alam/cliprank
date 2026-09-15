class HashPayloadValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    record.errors.add(attribute, "must be a JSON object") unless value.is_a?(Hash)
  end
end
