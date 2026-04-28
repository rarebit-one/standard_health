# frozen_string_literal: true

Rails.application.routes.draw do
  mount StandardHealth::Engine => "/health"
end
