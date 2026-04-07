# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'PangeaDatadog::VERSION' do
  it 'is defined' do
    expect(defined?(PangeaDatadog::VERSION)).to be_truthy
  end

  it 'is a non-empty string' do
    expect(PangeaDatadog::VERSION).to be_a(String)
    expect(PangeaDatadog::VERSION).not_to be_empty
  end

  it 'follows semantic versioning format' do
    expect(PangeaDatadog::VERSION).to match(/\A\d+\.\d+\.\d+/)
  end
end
