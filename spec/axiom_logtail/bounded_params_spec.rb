# frozen_string_literal: true

require 'logtail/events/controller_call'

# The regression these guard is not a crash -- it is a bill. Unbounded params can
# make a single webhook endpoint the majority of a log spend, because the event
# serialises params twice (structured field plus message string) with no cap on
# either.
#
# Assertions cover BOTH representations. Capping the structured field alone
# leaves half the waste in place, which is exactly the mistake that looks like a
# fix. Where a size assertion could pass against the UNPATCHED gem it is paired
# with a content assertion that cannot.
RSpec.describe AxiomLogtail::BoundedParams do
  # ~40 KB, an order of magnitude over the bound, so no size assertion can pass
  # by accident of a small fixture.
  let(:fat) { { 'items' => Array.new(200) { |i| { 'id' => "id#{i}", 'body' => 'x' * 180 } } } }

  def unserialisable
    object = Object.new
    def object.to_json(*)
      raise 'cannot encode'
    end

    def object.as_json(*)
      raise 'cannot encode'
    end
    object
  end

  describe '.bound' do
    it 'returns params untouched when they already fit' do
      params = { 'id' => '42', 'ref' => 'refs/heads/main' }

      expect(described_class.bound(params)).to equal(params)
    end

    it 'returns nil and empty params untouched' do
      expect(described_class.bound(nil)).to be_nil
      expect(described_class.bound({})).to eq({})
    end

    it 'replaces the oversized value but keeps the small ones' do
      bounded = described_class.bound('id' => '42', 'key' => 'abc', 'payload' => fat)

      expect(bounded['id']).to eq('42')
      expect(bounded['key']).to eq('abc')
      expect(bounded.to_json).not_to include('id199')
    end

    it 'records the pre-truncation size' do
      original = { 'payload' => fat }

      expect(described_class.bound(original)[described_class::TRUNCATED_KEY])
        .to eq(original.to_json.bytesize)
    end

    it 'does not mutate the params it was given' do
      params = { 'payload' => fat }

      expect { described_class.bound(params) }.not_to(change { params['payload'] })
    end

    # Regression: bounding only the top level collapsed an ordinary nested form
    # post to a single marker, losing which resource was being edited.
    it 'preserves the structure of a nested payload, replacing only the fat leaf' do
      bounded = described_class.bound(
        'id' => '42',
        'config_file' => { 'path' => 'app/config.yml', 'language' => 'yaml', 'body' => 'x' * 4000 }
      )

      expect(bounded['config_file']['path']).to eq('app/config.yml')
      expect(bounded['config_file']['language']).to eq('yaml')
      expect(bounded['config_file']['body']).to match(/\A\[truncated String: \d+ bytes\]\z/)
    end

    # Regression: summing per-value sizes ignored key bytes, so a huge key name
    # bypassed the cap entirely.
    it 'counts key bytes, so a huge key name cannot bypass the cap' do
      params = { 'k' * 5000 => 'v', 'id' => '42' }

      expect(described_class.bound(params).to_json.bytesize).to be <= described_class::BYTE_LIMIT
    end

    # Regression: the bounded key was prefix + byte length, so two oversized keys
    # sharing a prefix and length collided and one value was silently dropped.
    it 'keeps two same-prefix, same-length oversized keys distinct' do
      shared = 'k' * 5000
      bounded = described_class.bound("#{shared}alpha" => 'first', "#{shared}bravo" => 'second')
      surviving = bounded.reject { |key, _| key.to_s.start_with?('_params_') }

      expect(surviving.keys.uniq.size).to eq(2)
      expect(surviving.values).to contain_exactly('first', 'second')
    end

    it 'keeps a bounded key within its own byte limit' do
      bounded = described_class.bound('k' * 5000 => 'v')
      key = bounded.keys.reject { |k| k.to_s.start_with?('_params_') }.first

      expect(key.bytesize).to be <= described_class::MAX_KEY_BYTES
    end

    # Regression: an unserialisable value was scored as a fixed size. When the
    # total then fit, params were returned unchanged and the gem's own to_json
    # raised -- dropping the event and writing a backtrace to the same paid sink.
    it 'replaces an unserialisable value even when nothing else forces a prune' do
      bounded = described_class.bound('bad' => unserialisable)

      expect(bounded['bad']).to eq(described_class::UNSERIALIZABLE)
      expect { bounded.to_json }.not_to raise_error
    end

    it 'does not fabricate a byte count for a value it could not encode' do
      expect(described_class.bound('bad' => unserialisable))
        .not_to have_key(described_class::TRUNCATED_KEY)
    end
  end

  # The contract is one sentence: whatever goes in, what comes out fits.
  # Asserting it per-shape is how a bound stops being aspirational -- the bug
  # that mattered was a `squeeze` that GREW a payload of many tiny pairs from
  # 3,191 to 11,022 bytes.
  describe 'the bound always holds' do
    {
      'many tiny pairs (marker larger than the value it replaces)' =>
        -> { 300.times.map { |i| ["k#{i}", 'v'] }.to_h },
      'four values just under the leaf limit (JSON structural bytes)' =>
        -> { 4.times.map { |i| ["f#{i}", 'x' * 504] }.to_h },
      'one enormous value' => -> { { 'payload' => 'x' * 500_000 } },
      'enormous key name' => -> { { 'k' * 5000 => 'v' } },
      'thousands of keys' => -> { 5000.times.map { |i| ["key#{i}", "value#{i}"] }.to_h },
      'deeply nested' => -> { 12.times.inject('x' * 3000) { |acc, i| { "level#{i}" => acc } } },
      'huge array of small items' => -> { { 'items' => Array.new(5000) { |i| "id#{i}" } } }
    }.each do |label, build|
      it "fits for: #{label}" do
        expect(described_class.bound(build.call).to_json.bytesize)
          .to be <= described_class::BYTE_LIMIT
      end
    end

    it 'never returns something larger than it was given' do
      tiny = 300.times.map { |i| ["k#{i}", 'v'] }.to_h

      expect(described_class.bound(tiny).to_json.bytesize).to be < tiny.to_json.bytesize
    end

    it 'keeps the small high-value keys when it has to drop entries' do
      params = { 'id' => '42', 'project_id' => 'abc' }
               .merge(200.times.map { |i| ["filler#{i}", 'z' * 40] }.to_h)

      bounded = described_class.bound(params)

      expect(bounded['id']).to eq('42')
      expect(bounded['project_id']).to eq('abc')
      expect(bounded[described_class::DROPPED_KEY]).to be > 0
    end
  end

  describe '.safe_bound' do
    it 'degrades to a marker rather than raising if bounding itself fails' do
      allow(described_class).to receive(:bound).and_raise(NoMethodError, 'boom')

      expect(described_class.safe_bound('id' => '42')).to eq(described_class::FAILED_KEY => true)
    end
  end

  # The point of patching the event rather than the two serialisations
  # separately: bound the params once and both representations shrink together.
  describe '.install!' do
    before { described_class.install! }

    def event(params)
      Logtail::Events::ControllerCall.new(
        controller: 'WebhooksController', action: 'receive', format: 'JSON', params: params
      )
    end

    it 'is idempotent' do
      expect(described_class.install!).to be(false)
    end

    it 'bounds the structured params field' do
      json = event('payload' => fat).to_hash[:controller_called][:params_json]

      expect(json.bytesize).to be <= described_class::BYTE_LIMIT
      expect(json).not_to include('id199')
    end

    # Paired with a content assertion deliberately: a loose size ceiling alone
    # would pass against the unpatched gem and prove nothing.
    it 'bounds the params copy embedded in the message' do
      message = event('payload' => fat).message

      expect(message).to include('Processing by WebhooksController#receive')
      expect(message).not_to include('id199')
      expect(message.bytesize).to be <= described_class::BYTE_LIMIT * 2
    end

    it 'never raises on a payload that cannot be serialised' do
      expect { event('bad' => unserialisable).to_hash }.not_to raise_error
    end

    it 'leaves an ordinary request completely intact' do
      params = { 'id' => '42', 'ref' => 'refs/heads/main' }
      built = event(params)

      expect(JSON.parse(built.to_hash[:controller_called][:params_json])).to eq(params)
      expect(built.message).to include('refs/heads/main')
    end
  end
end
