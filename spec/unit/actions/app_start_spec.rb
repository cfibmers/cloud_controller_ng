require 'spec_helper'
require 'actions/app_start'

module VCAP::CloudController
  RSpec.describe AppStart do
    let(:user_guid) { 'some-guid' }
    let(:user_email) { '1@2.3' }
    let(:user_audit_info) { UserAuditInfo.new(user_email: user_email, user_guid: user_guid) }

    describe '#start' do
      let(:environment_variables) { { 'FOO' => 'bar' } }

      context 'when the app has a docker lifecycle' do
        let(:app) do
          AppModel.make(
            :docker,
            desired_state:         'STOPPED',
            environment_variables: environment_variables
          )
        end
        let(:package) { PackageModel.make(:docker, app: app, state: PackageModel::READY_STATE) }
        let!(:droplet) { DropletModel.make(:docker, app: app, package: package, state: DropletModel::STAGED_STATE, docker_receipt_image: package.image) }
        let!(:process1) { ProcessModel.make(:process, state: 'STOPPED', app: app) }
        let!(:process2) { ProcessModel.make(:process, state: 'STOPPED', app: app) }

        before do
          app.update(droplet: droplet)
          VCAP::CloudController::FeatureFlag.make(name: 'diego_docker', enabled: true, error_message: nil)
        end

        it 'starts the app' do
          described_class.start(app: app, user_audit_info: user_audit_info)
          expect(app.desired_state).to eq('STARTED')
        end

        it 'sets the docker image on the process' do
          described_class.start(app: app, user_audit_info: user_audit_info)

          process1.reload
          expect(process1.docker_image).to eq(droplet.docker_receipt_image)
        end
      end

      context 'when the app has a buildpack lifecycle' do
        let(:app) do
          AppModel.make(:buildpack,
            desired_state:         'STOPPED',
            environment_variables: environment_variables)
        end
        let!(:droplet) { DropletModel.make(app: app) }
        let!(:process1) { ProcessModel.make(:process, state: 'STOPPED', app: app) }
        let!(:process2) { ProcessModel.make(:process, state: 'STOPPED', app: app) }

        before do
          app.update(droplet: droplet)
        end

        it 'sets the desired state on the app' do
          described_class.start(app: app, user_audit_info: user_audit_info)
          expect(app.desired_state).to eq('STARTED')
        end

        it 'creates an audit event' do
          expect_any_instance_of(Repositories::AppEventRepository).to receive(:record_app_start).with(
            app,
            user_audit_info,
          )

          described_class.start(app: app, user_audit_info: user_audit_info)
        end

        context 'when the app is invalid' do
          before do
            allow_any_instance_of(AppModel).to receive(:update).and_raise(Sequel::ValidationFailed.new('some message'))
          end

          it 'raises a InvalidApp exception' do
            expect {
              described_class.start(app: app, user_audit_info: user_audit_info)
            }.to raise_error(AppStart::InvalidApp, 'some message')
          end
        end

        context 'and the droplet has a package' do
          let!(:droplet) do
            DropletModel.make(
              app:     app,
              package: package,
              state:   DropletModel::STAGED_STATE,
            )
          end
          let(:package) { PackageModel.make(app: app, package_hash: 'some-awesome-thing', state: PackageModel::READY_STATE) }

          it 'sets the package hash correctly on the process' do
            described_class.start(app: app, user_audit_info: user_audit_info)

            process1.reload
            expect(process1.package_hash).to eq(package.package_hash)
            expect(process1.package_state).to eq('STAGED')

            process2.reload
            expect(process2.package_hash).to eq(package.package_hash)
            expect(process2.package_state).to eq('STAGED')
          end
        end
      end

      context 'when the app has exceeded the quota limit' do
        let(:quota) { QuotaDefinition.make(memory_limit: 0) }
        let(:org) { Organization.make(quota_definition: quota) }
        let(:space_quota) { SpaceQuotaDefinition.make(memory_limit: 4096, organization: org) }
        let(:space) { Space.make(name: 'hi', organization: org, space_quota_definition: space_quota) }
        let(:app) do
          AppModel.make(
            :docker,
             desired_state:         'STOPPED',
             environment_variables: environment_variables,
             space: space
          )
        end
        let!(:process1) { ProcessModel.make(:process, state: 'STOPPED', app: app) }
        let!(:process2) { ProcessModel.make(:process, state: 'STOPPED', app: app) }

        context 'for org quota' do
          it 'should not start app' do
            expect {
              AppStart.start(app: app, user_audit_info: user_audit_info)
            }.to raise_error(AppStart::InvalidApp, /quota_exceeded/)
            expect(app.space.organization.quota_definition.memory_limit).to eq 0
            expect(process1.state).to eq('STOPPED')
            expect(process2.state).to eq('STOPPED')
          end

          it 'raises a exception' do
            expect {
              AppStart.start(app: app, user_audit_info: user_audit_info)
            }.to raise_error(AppStart::InvalidApp, /quota_exceeded/)
          end
        end

        context 'for space quota' do
          before do
            quota.memory_limit = 2000
            quota.save
            space_quota.memory_limit = 0
            space_quota.save
          end

          it 'should not start app' do
            expect {
              AppStart.start(app: app, user_audit_info: user_audit_info)
            }.to raise_error(AppStart::InvalidApp, /space_quota_exceeded/)
            expect(app.space.space_quota_definition.memory_limit).to eq 0
            expect(process1.state).to eq('STOPPED')
            expect(process2.state).to eq('STOPPED')
          end

          it 'raises a exception' do
            expect {
              AppStart.start(app: app, user_audit_info: user_audit_info)
            }.to raise_error(AppStart::InvalidApp,)
          end
        end

        it 'should not raise error when reducing memory from above quota to at/below quota' do 
          org.quota_definition = QuotaDefinition.make(memory_limit: 64)
          org.save
 
          process1.memory = 10
          process1.save
          process2.memory = 10
          process2.save
          expect { AppStart.start(app: app, user_audit_info: user_audit_info) }.to_not raise_error
        end
      end

      context 'when the app has exceeded the instance memory limit' do
        subject(:process) { ProcessModelFactory.make }
        let(:quota) do
          QuotaDefinition.make(memory_limit: 128, instance_memory_limit: 512)
        end
        let(:space_quota) do
          SpaceQuotaDefinition.make(memory_limit: 128, organization: org)
        end
        let(:org) { Organization.make(quota_definition: quota) }
        let(:space) { Space.make(name: 'hi', organization: org, space_quota_definition: space_quota) }
        let(:app) { AppModel.make(space: space) }
        subject!(:process) { ProcessModelFactory.make(app: app, memory: 64, instances: 2, state: 'STOPPED') }

        context 'for org' do
          it 'should raise error when memory exceeds the max limit' do
            process.memory = 525
            process.save
            expect { AppStart.start(app: app, user_audit_info: user_audit_info) }.to raise_error(/instance_memory_limit_exceeded/)
          end

          it 'should not raise when memory is below the max limit' do
            process.memory = 510
            process.save
            expect { AppStart.start(app: app, user_audit_info: user_audit_info) }.to_not raise_error
            expect(process.memory).to eq 510
            expect(quota.instance_memory_limit).to eq 512
          end

          before do
            process.memory = 525
            process.save
          end

          it 'should not raise error when memory is reduced from above max limit to below max limit' do
            process.memory = 510
            process.save
            expect { AppStart.start(app: app, user_audit_info: user_audit_info) }.to_not raise_error
            expect(process.memory).to eq 510
            expect(app.space.organization.quota_definition.instance_memory_limit).to eq 512
          end

          it 'should raise error when memory increased from below max limit to above max limit' do
            process.reload
            process.memory = 525
            process.save
            expect { AppStart.start(app: app, user_audit_info: user_audit_info) }.to raise_error(/instance_memory_limit_exceeded/)
          end

          it 'should raise error when number of instances has been reduced but max limit is still exceeded' do
            process.memory = 525
            expect(process.memory).to eq 525
            process.instances = 1
            process.save
            expect { AppStart.start(app: app, user_audit_info: user_audit_info) }.to raise_error(/instance_memory_limit_exceeded/)
          end
        end

        context 'for space' do
          before do
            quota.instance_memory_limit = -1
            quota.save
            space_quota.instance_memory_limit = 512
            space_quota.save
          end

          it 'should raise error when memory exceeds the max limit' do
            process.memory = 525
            process.save
            expect { AppStart.start(app: app, user_audit_info: user_audit_info) }.to raise_error(/space_instance_memory_limit_exceeded/)
          end

          it 'should not raise when memory is below the max limit' do
            process.memory = 510
            process.save
            expect { AppStart.start(app: app, user_audit_info: user_audit_info) }.to_not raise_error
            expect(process.memory).to eq 510
            expect(space.space_quota_definition.instance_memory_limit).to eq 512
          end

          before do
            process.memory = 525
            process.save
          end

          it 'should not raise error when memory is reduced from above max limit to below max limit' do
            process.memory = 510
            process.save
            expect { AppStart.start(app: app, user_audit_info: user_audit_info) }.to_not raise_error
            expect(process.memory).to eq 510
            expect(space.space_quota_definition.instance_memory_limit).to eq 512
          end

          it 'should raise error when memory increased from below max limit to above max limit' do
            process.reload
            process.memory = 525
            process.save
            expect { AppStart.start(app: app, user_audit_info: user_audit_info) }.to raise_error(/space_instance_memory_limit_exceeded/)
          end

          it 'should raise error when number of instances has been reduced but max limit is still exceeded' do
            process.memory = 525
            expect(process.memory).to eq 525
            process.instances = 1
            process.save
            expect { AppStart.start(app: app, user_audit_info: user_audit_info) }.to raise_error(/space_instance_memory_limit_exceeded/)
          end
        end
      end

      describe '#start_without_event' do
        let(:app) { AppModel.make(:buildpack, desired_state: 'STOPPED') }

        it 'sets the desired state on the app' do
          described_class.start_without_event(app)
          expect(app.desired_state).to eq('STARTED')
        end

        it 'does not create an audit event' do
          expect_any_instance_of(Repositories::AppEventRepository).not_to receive(:record_app_start)
          described_class.start_without_event(app)
        end
      end
    end
  end
end
