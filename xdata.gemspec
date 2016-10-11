# -*- encoding: utf-8 -*-
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'xdata'

Gem::Specification.new do |gem|
  gem.name          = "xdata"
  gem.version       = XData::VERSION
  gem.authors       = ["Tom Demeyer"]
  gem.email         = ["tom@waag.org"]
  gem.description   = %q{Provides analysis of (geo)data files.}
  gem.summary       = %q{Provides analisis of (geo)data files. Both interactive and command-line driven}
  gem.homepage      = "http://waag.org"
  gem.licenses      = ['MIT']

  gem.files         = `git ls-files`.split($/) - ["xdata.gemspec"]
  gem.executables   = ['xdata']
  # gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.require_paths = ["lib"]

  gem.add_dependency('i18n', '~> 0.7')
  gem.add_dependency('dbf', '~> 2.0')
  gem.add_dependency('georuby', '~> 2.0')
  gem.add_dependency('rgeo', '~> 0.5')
  gem.add_dependency('proj4rb', '~> 1.0')
  gem.add_dependency('charlock_holmes', '~> 0.6')
  gem.add_dependency('curses', '~> 1.0')
  
  # gem.add_development_dependency "rspec", '~> 3.0'
end

