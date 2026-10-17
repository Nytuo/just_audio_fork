Pod::Spec.new do |s|
  s.name             = 'just_audio'
  s.version          = '0.0.1'
  s.summary          = 'Flutter audio player'
  s.homepage         = 'https://github.com/ryanheise/just_audio'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*.{h,m}'
  s.public_header_files = 'Classes/include/**/*.h'
  s.frameworks = 'Accelerate', 'MediaToolbox'
  s.dependency 'Flutter'
  s.tvos.deployment_target = '13.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
