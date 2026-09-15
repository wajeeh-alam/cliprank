class ArrayPayloadValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    record.errors.add(attribute, "must be a JSON array") unless value.is_a?(Array)
  end
end
