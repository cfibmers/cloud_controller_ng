require 'spec_helper'
require 'actions/app_delete'

module VCAP::CloudController
  RSpec.describe AppDelete do
    subject(:app_delete) { AppDelete.new(user_audit_info) }
    let(:user) { User.make }
    let(:user_email) { 'user@example.com' }
    let(:user_audit_info) { UserAuditInfo.new(user_guid: user.guid, user_email: user_email) }

    let!(:app) { AppModel.make }
    let!(:app_dataset) { [app] }

    describe '#delete' do
      it 'deletes the app record' do
        expect {
          app_delete.delete(app_dataset)
        }.to change { AppModel.count }.by(-1)
        expect(app.exists?).to be_falsey
      end

      it 'creates an audit event' do
        expect_any_instance_of(Repositories::AppEventRepository).to receive(:record_app_delete_request).with(
          app,
          app.space,
          user_audit_info
        )

        app_delete.delete(app_dataset)
      end

      describe 'recursive deletion' do
        it 'deletes associated packages' do
          package = PackageModel.make(app: app)

          expect {
            app_delete.delete(app_dataset)
          }.to change { PackageModel.count }.by(-1)
          expect(package.exists?).to be_falsey
          expect(app.exists?).to be_falsey
        end

        it 'deletes associated builds' do
          build = BuildModel.make(app: app)

          expect {
            app_delete.delete(app_dataset)
          }.to change { BuildModel.count }.by(-1)
          expect(build.exists?).to be_falsey
          expect(app.exists?).to be_falsey
        end

        it 'deletes associated droplets' do
          droplet = DropletModel.make(app: app)

          expect {
            app_delete.delete(app_dataset)
          }.to change { DropletModel.count }.by(-1)
          expect(droplet.exists?).to be_falsey
          expect(app.exists?).to be_falsey
        end

        it 'deletes associated processes' do
          process = ProcessModel.make(app: app)

          expect {
            app_delete.delete(app_dataset)
          }.to change { ProcessModel.count }.by(-1)
          expect(process.exists?).to be_falsey
          expect(app.exists?).to be_falsey
        end

        it 'deletes associated routes' do
          route_mapping = RouteMappingModel.make(app: app, route: Route.make)

          expect {
            app_delete.delete(app_dataset)
          }.to change { RouteMappingModel.count }.by(-1)
          expect(route_mapping.exists?).to be_falsey
          expect(app.exists?).to be_falsey
        end

        it 'deletes associated tasks' do
          task_model = TaskModel.make(app: app, name: 'task1', state: TaskModel::SUCCEEDED_STATE)

          expect {
            app_delete.delete(app_dataset)
          }.to change { TaskModel.count }.by(-1)
          expect(task_model.exists?).to be_falsey
          expect(app.exists?).to be_falsey
        end

        it 'deletes the buildpack caches' do
          delete_buildpack_cache_jobs = Delayed::Job.where(Sequel.lit("handler like '%BuildpackCacheDelete%'"))
          expect { app_delete.delete(app_dataset) }.to change { delete_buildpack_cache_jobs.count }.by(1)
          job = delete_buildpack_cache_jobs.last

          expect(job.handler).to include(app.guid)
          expect(job.queue).to eq('cc-generic')
          expect(app.exists?).to be_falsey
        end

        describe 'deleting service bindings' do
          it 'deletes associated service bindings' do
            allow_any_instance_of(VCAP::Services::ServiceBrokers::V2::Client).to receive(:unbind)

            binding = ServiceBinding.make(app: app, service_instance: ManagedServiceInstance.make(space: app.space))

            expect {
              app_delete.delete(app_dataset)
            }.to change { ServiceBinding.count }.by(-1)
            expect(binding.exists?).to be_falsey
            expect(app.exists?).to be_falsey
          end

          context 'when service binding delete returns errors' do
            before do
              allow_any_instance_of(ServiceBindingDelete).to receive(:delete).and_return([StandardError.new('first'), StandardError.new('second')])
            end

            it 'raises the first error in the list' do
              expect {
                app_delete.delete(app_dataset)
              }.to raise_error(StandardError, 'first')
            end
          end
        end
      end
    end

    describe '#delete_without_event' do
      it 'deletes the app record' do
        expect {
          app_delete.delete_without_event(app_dataset)
        }.to change { AppModel.count }.by(-1)
        expect(app.exists?).to be_falsey
      end

      it 'creates an audit event' do
        expect_any_instance_of(Repositories::AppEventRepository).not_to receive(:record_app_delete_request)
        app_delete.delete_without_event(app_dataset)
      end
    end
  end
end
