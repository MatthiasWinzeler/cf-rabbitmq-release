require 'spec_helper'

require 'json'
require 'ostruct'
require 'tempfile'
require 'nokogiri'

require 'hula'
require 'hula/bosh_manifest'
require 'prof/marketplace_service'
require 'prof/service_instance'
require 'prof/cloud_foundry'
require 'prof/test_app'
require 'rabbitmq/http/client'

require "mqtt"
require "stomp"

require File.expand_path('../../../../system_test/test_app/lib/lab_rat/aggregate_health_checker.rb', __FILE__)


RSpec.describe 'Logging a Cloud Foundry service broker' do
  RMQ_BROKER_JOB = "rabbitmq-broker"
  RMQ_BROKER_JOB_INDEX = 0

  RMQ_SERVER_JOB = "rabbitmq-server"
  RMQ_SERVER_Z1_JOB_INDEX = 0
  RMQ_SERVER_Z2_JOB_INDEX = 1

  RMQ_SERVER_PORT = 15672

  let(:service_name) {environment.bosh_manifest.job('rabbitmq-broker').properties['rabbitmq-broker']['service']['name']}
  let(:service) { Prof::MarketplaceService.new(name: service_name, plan: 'standard') }
  let(:rmq_broker_host)  { bosh_director.ips_for_job(RMQ_BROKER_JOB, environment.bosh_manifest.deployment_name)[RMQ_BROKER_JOB_INDEX] }
  let(:rmq_server_z1_host)  { bosh_director.ips_for_job(RMQ_SERVER_JOB, environment.bosh_manifest.deployment_name)[RMQ_SERVER_Z1_JOB_INDEX] }
  let(:rmq_server_z2_host)  { bosh_director.ips_for_job(RMQ_SERVER_JOB, environment.bosh_manifest.deployment_name)[RMQ_SERVER_Z2_JOB_INDEX] }
  let(:rmq_broker_stdout_log) { ssh_gateway.execute_on(rmq_broker_host, "cat /var/vcap/sys/log/rabbitmq-broker/startup_stdout.log") }
  let(:rmq_broker_stderr_log) { ssh_gateway.execute_on(rmq_broker_host, "cat /var/vcap/sys/log/rabbitmq-broker/startup_stderr.log") }

  describe 'provisions a service' do
    it 'and writes the operation into the stdout logs', :creates_service_key do
      cf.provision_and_create_service_key(service) do |_, _, service_key_data|
        service_instance_id = service_key_data['vhost']
        expect(rmq_broker_stdout_log).to include "Asked to provision a service: #{service_instance_id}"
      end
    end

    context 'when the nodes are down' do
      it 'writes the error in stderr log', :creates_service_key do
        stop_connections_to_job(:hosts => [rmq_server_z1_host, rmq_server_z2_host], :port => RMQ_SERVER_PORT) do
          expect{ cf.provision_and_create_service_key(service) }.to raise_error do |e|
            service_instance_id = get_uuid(e.message)
            expect(rmq_broker_stderr_log).to include "Failed to provision a service: #{service_instance_id}"
          end
        end
      end
    end
  end

  describe 'deprovisions a service' do
    it 'and writes the operation into the stdout logs', :creates_service_key do
      cf.provision_and_create_service_key(service) do |service_instance, service_key, service_key_data|
        @service_instance_id = service_key_data['vhost']
      end

      expect(rmq_broker_stdout_log).to include "Asked to deprovision a service: #{@service_instance_id}"
    end

    context 'when the nodes are down' do
      it 'writes the error into stderr log', :creates_service_key do
        cf.provision_service(service) do |service_instance|
          stop_connections_to_job(:hosts => [rmq_server_z1_host, rmq_server_z2_host], :port => RMQ_SERVER_PORT) do
            expect { cf.delete_service_instance_and_unbind(service_instance, :allow_failure => false) }.to raise_error do |e|
              service_instance_id = get_uuid(e.message)
              expect(rmq_broker_stderr_log).to include "Failed to deprovision a service: #{service_instance_id}"
            end
          end
        end
      end
    end
  end

  describe 'binds a service' do
    it 'and writes the operation into the stdout logs', :creates_service_key, :pushes_cf_app do
      cf.provision_and_create_service_key(service) do |service_instance, service_key, service_key_data|
        cf.push_app_and_bind_with_service_instance(test_app, service_instance) do |_, _|
          service_instance_id = service_key_data['vhost']
          expect(rmq_broker_stdout_log).to include "Asked to bind a service: #{service_instance_id}"
        end
      end
    end

    context 'when the nodes are down' do
      it 'writes the error into the stderr logs', :pushes_cf_app do
        cf.provision_service(service) do |service_instance|
          cf.push_app(test_app) do |pushed_app|

            stop_connections_to_job(:hosts => [rmq_server_z1_host, rmq_server_z2_host], :port => RMQ_SERVER_PORT) do
              expect { cf.bind_service_and_keep_running(pushed_app.name, service_instance.name) }.to raise_error do |e|
                service_instance_id = get_uuid(e.message)
                expect(rmq_broker_stderr_log).to include "Failed to bind a service: #{service_instance_id}"
              end
            end
          end
        end
      end
    end
  end

  describe 'unbinds a service' do
    it 'and writes the operation into the stdout logs', :creates_service_key, :pushes_cf_app do
      cf.provision_and_create_service_key(service) do |service_instance, service_key, service_key_data|
        cf.push_app_and_bind_with_service_instance(test_app, service_instance) { |_, _| }
        service_instance_id = service_key_data['vhost']
        expect(rmq_broker_stdout_log).to include "Asked to unbind a service: #{service_instance_id}"
      end
    end

    context 'when the nodes are down' do
      it 'writes the error into tthe stderr logs', :pushes_cf_app do
        cf.provision_service(service) do |service_instance|
          cf.push_app(test_app) do |pushed_app|
            cf.bind_service_and_keep_running(pushed_app.name, service_instance.name)

            stop_connections_to_job(:hosts=>[rmq_server_z1_host, rmq_server_z2_host], :port => RMQ_SERVER_PORT) do
              expect { cf.unbind_app_from_service(pushed_app, service_instance) }.to raise_error do |e|
                service_instance_location = e.message.index("service_instances")
                uuid_string = e.message[service_instance_location, e.message.length]
                service_instance_id = get_uuid(uuid_string)
                expect(rmq_broker_stderr_log).to include "Failed to unbind a service: #{service_instance_id}"
              end
            end
          end
        end
      end
    end
  end
end
