require 'spec_helper'
require 'flapjack/gateways/aws_sns'

describe Flapjack::Gateways::AwsSns, :logger => true do

  let(:lock) { double(Monitor) }

  let(:time) { Time.new(2013, 10, 31, 13, 45) }

  let(:time_str) { Time.at(time).strftime('%-d %b %H:%M') }

  let(:config) { {'region' => 'us-east-1',
                  'access_key' => 'AKIAIOSFODNN7EXAMPLE',
                  'secret_key' => 'secret'
                 }
               }

  let(:message) { {'notification_type'  => 'recovery',
                   'contact_first_name' => 'John',
                   'contact_last_name'  => 'Smith',
                   'state'              => 'ok',
                   'summary'            => 'smile',
                   'last_state'         => 'problem',
                   'last_summary'       => 'frown',
                   'time'               => time.to_i,
                   'address'            => 'arn:aws:sns:us-east-1:698519295917:My-Topic',
                   'event_id'           => 'example.com:ping',
                   'id'                 => '123456789',
                   'duration'           => 55,
                   'state_duration'     => 23
                  }
                }

  it "sends an SMS message" do
    req = stub_request(:post, "http://sns.us-east-1.amazonaws.com/").
      with(:query => hash_including({'Action'           => 'Publish',
                                     'AWSAccessKeyId'   => config['access_key'],
                                     'TopicArn'         => message['address'],
                                     'SignatureVersion' => '2',
                                     'SignatureMethod'  => 'HmacSHA256'})).
      to_return(:status => 200)

    EM.synchrony do
      Flapjack::Gateways::AwsSns.instance_variable_set('@config', config)
      Flapjack::Gateways::AwsSns.instance_variable_set('@logger', @logger)
      Flapjack::Gateways::AwsSns.start
      Flapjack::Gateways::AwsSns.perform(message)
      EM.stop
    end
    expect(req).to have_been_requested
  end

  it "does not send an SMS message with an invalid config" do
    EM.synchrony do
      Flapjack::Gateways::AwsSns.instance_variable_set('@config', config.reject {|k, v| k == 'secret_key'})
      Flapjack::Gateways::AwsSns.instance_variable_set('@logger', @logger)
      Flapjack::Gateways::AwsSns.start
      Flapjack::Gateways::AwsSns.perform(message)
      EM.stop
    end

    expect(WebMock).not_to have_requested(:get, "http://sns.us-east-1.amazonaws.com/")
  end

  context "#string_to_sign" do

    let(:method) { 'post' }

    let(:host) { 'sns.us-east-1.AmazonAWS.com' }

    let(:uri) { '/' }

    let(:query) { {'TopicArn' => 'HelloWorld',
                  'Action' => 'Publish'} }

    let(:string_to_sign) { Flapjack::Gateways::AwsSns.string_to_sign(method, host, uri, query) }

    let(:lines) { string_to_sign.split(/\n/) }

    it 'should put the method on the first line' do
      expect(lines[0]).to eq("POST")
    end

    it 'should put the downcased hostname on the second line' do
      expect(lines[1]).to eq("sns.us-east-1.amazonaws.com")
    end

    it 'should put the URI on the third line' do
      expect(lines[2]).to eq("/")
    end

    it 'should put the encoded, sorted query-string on the fourth line' do
      expect(lines[3]).to eq("Action=Publish&TopicArn=HelloWorld")
    end

  end

  context "#get_signature" do
    let(:method) { 'GET' }

    let(:host) { 'elasticmapreduce.amazonaws.com' }

    let(:uri) { '/' }

    let(:query) { {'AWSAccessKeyId' => 'AKIAIOSFODNN7EXAMPLE',
                   'Action' => 'DescribeJobFlows',
                   'SignatureMethod' => 'HmacSHA256',
                   'SignatureVersion' => '2',
                   'Timestamp' => '2011-10-03T15:19:30',
                   'Version' => '2009-03-31'} }

    let(:secret_key) { 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY' }

    let(:string_to_sign) { Flapjack::Gateways::AwsSns.string_to_sign(method, host, uri, query) }

    let(:signature) { Flapjack::Gateways::AwsSns.get_signature(secret_key, string_to_sign) }

    it 'should HMAC-SHA256 and base64 encode the signature' do
      expect(signature).to eq("i91nKc4PWAt0JJIdXwz9HxZCJDdiy6cf/Mj6vPxyYIs=")
    end
  end

end
