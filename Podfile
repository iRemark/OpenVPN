source 'https://github.com/cocoapods/specs.git'
use_frameworks!

def shared_pods
    #pod 'TunnelKit', '~> 1.3.0'
    pod 'TunnelKit', :git => 'https://github.com/keeshux/tunnelkit', :commit => 'caea662'
    #pod 'TunnelKit', :path => '../../personal/tunnelkit'
end

target 'VPN' do
    platform :ios, '11.0'
    shared_pods
    pod 'MBProgressHUD'
end
target 'VPNTunnel' do
    platform :ios, '11.0'
    shared_pods
end
 
