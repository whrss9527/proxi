import Foundation

// 已有的跨进程页面请求；不重新启动应用、不需要辅助功能权限。
guard CommandLine.arguments.count == 2 else { exit(1) }
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.whrss9527.proxyswitch.engineSettingsPage"),
    object: CommandLine.arguments[1], userInfo: nil, deliverImmediately: true
)
