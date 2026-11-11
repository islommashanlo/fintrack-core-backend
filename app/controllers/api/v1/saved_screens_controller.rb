# frozen_string_literal: true

module Api
  module V1
    class SavedScreensController < ProtectedController
      before_action :require_saved_screens
      rescue_from ActiveRecord::RecordNotUnique, with: :render_duplicate_name

      def index
        values = SavedScreenParameters.list(read_parameters(allowed: SavedScreenParameters::LIST))
        page = CursorPage.new(parameters: values,
          context: { "resource" => "saved_screens", "user_id" => Current.user.id, "saved_screens" => true },
          sorts: SavedScreensQuery::SORTS, default_sort: "name", bounds: { "saved_screens" => Current.user.saved_screens }, as_of:)
        render_read_page(SavedScreensQuery.call(user: Current.user, page:, filters: values), SavedScreenSerializer)
      end

      def show
        read_parameters(allowed: [], path_keys: [ :id ])
        render json: { data: SavedScreenSerializer.render(Current.user.saved_screens.find(screen_id)) }
      end

      def create
        values = SavedScreenParameters.write(params.except(:controller, :action, :format).to_unsafe_h, create: true)
        screen = SavedScreenStore.create(user: Current.user, attributes: values)
        render json: { data: SavedScreenSerializer.render(screen) }, status: :created
      end

      def update
        values = SavedScreenParameters.write(params.except(:controller, :action, :format, :id).to_unsafe_h)
        screen = SavedScreenStore.update(user: Current.user, id: screen_id, attributes: values)
        render json: { data: SavedScreenSerializer.render(screen) }
      end

      def destroy
        read_parameters(allowed: [], path_keys: [ :id ])
        SavedScreenStore.destroy(user: Current.user, id: screen_id)
        head :no_content
      end

      private

      def require_saved_screens
        SavedScreenStore.require_access!(Current.user)
      end

      def screen_id
        SavedScreenParameters.id!(params[:id])
      end

      def render_duplicate_name
        render json: { error: { code: "VALIDATION_FAILED", message: "Invalid details", details: { name: [ "has already been taken" ] } } }, status: :unprocessable_entity
      end
    end
  end
end
