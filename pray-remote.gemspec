# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'pray-remote/version'

Gem::Specification.new do |spec|
  spec.name          = "pray-remote"
  spec.version       = PrayRemote::VERSION
  spec.authors       = ["Mon-Ouie", "Jeff Dileo"]
  spec.email         = ["mon.ouie@gmail.com", "jtdileo@gmail.com"]

  spec.summary       = "Connect to Pry remotely"
  spec.description   = "Connect to Pry remotely"
  spec.homepage      = "https://github.com/chaosdata/pray-remote"
  spec.licenses      = ['zlib-acknowledgement']

  # Prevent pushing this gem to RubyGems.org. To allow pushes either set the 'allowed_push_host'
  # to allow pushing to a single host or delete this section to allow pushing to any host.
  if spec.respond_to?(:metadata)
    spec.metadata['allowed_push_host'] = "TODO: Set to 'http://mygemserver.com'"
  else
    raise "RubyGems 2.0 or newer is required to protect against " \
      "public gem pushes."
  end

  spec.files         = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "drab", "~> 0.1.0"
  spec.add_dependency "slop", "~> 3.0"
  spec.add_dependency "pry", "~> 0.9"
  spec.add_development_dependency "bundler", "~> 1.13"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "rspec", "~> 3.0"
end
