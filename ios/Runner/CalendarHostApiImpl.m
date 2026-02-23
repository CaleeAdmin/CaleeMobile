#import "CalendarHostApiImpl.h"
#import <EventKit/EventKit.h>

@interface CalendarHostApiImpl ()
@property (nonatomic, strong) EKEventStore *eventStore;
@end

@implementation CalendarHostApiImpl

- (instancetype)init {
    self = [super init];
    if (self) {
        _eventStore = [[EKEventStore alloc] init];
    }
    return self;
}

// 请求权限
- (void)requestPermissionForTask:(BOOL)forTask completion:(void (^)(NSNumber *_Nullable, FlutterError *_Nullable))completion {
    [self.eventStore requestAccessToEntityType:EKEntityTypeEvent completion:^(BOOL granted, NSError * _Nullable error) {
        if (error) {
            completion(nil, [FlutterError errorWithCode:@"PERMISSION_ERROR" message:error.localizedDescription details:nil]);
        } else {
            completion(@(granted), nil);
        }
    }];
}

// 获取日历列表（增加 Account 分组支持）
- (nullable NSArray<PlatformCalendar *> *)getCalendarsWithError:(FlutterError *_Nullable *_Nonnull)error {
    NSMutableArray<PlatformCalendar *> *calendars = [NSMutableArray array];

    EKAuthorizationStatus status = [EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent];
    if (status != EKAuthorizationStatusAuthorized) {
        *error = [FlutterError errorWithCode:@"PERMISSION_DENIED" message:@"Calendar access not authorized" details:nil];
        return nil;
    }

    // iOS 的分组逻辑：Source (账号) -> Calendar (日历)
    NSArray<EKSource *> *sources = [self.eventStore sources];

    for (EKSource *source in sources) {
        NSSet<EKCalendar *> *ekCalendars = [source calendarsForEntityType:EKEntityTypeEvent];

        for (EKCalendar *ekCalendar in ekCalendars) {
            PlatformCalendar *pc = [[PlatformCalendar alloc] init];
            pc.id = ekCalendar.calendarIdentifier;
            pc.name = ekCalendar.title;

            // 🚀 核心改动：设置账号分组信息
            pc.accountName = source.title; // 例如 "iCloud", "Gmail"
            pc.accountType = [self stringFromSourceType:source.sourceType];

            // 颜色转换
            CGColorRef colorRef = ekCalendar.CGColor;
            const CGFloat *components = CGColorGetComponents(colorRef);
            pc.color = [NSString stringWithFormat:@"#%02X%02X%02X",
                                                  (int)(components[0] * 255), (int)(components[1] * 255), (int)(components[2] * 255)];

            pc.isReadOnly = @(!ekCalendar.allowsContentModifications);
            pc.supportsEvents = @YES;
            pc.supportsTasks = @NO;
            pc.isSubscription = @(ekCalendar.type == EKCalendarTypeSubscription);
            if (ekCalendar.type == EKCalendarTypeSubscription) {
                pc.subscriptionUrl = ekCalendar.subscribedCalendarURL.absoluteString;
            }

            [calendars addObject:pc];
        }
    }
    return [calendars copy];
}

// 辅助方法：转换账号类型为字符串
- (NSString *)stringFromSourceType:(EKSourceType)type {
    switch (type) {
        case EKSourceTypeLocal: return @"Local";
        case EKSourceTypeExchange: return @"Exchange";
        case EKSourceTypeCalDAV: return @"CalDAV";
        case EKSourceTypeMobileMe: return @"iCloud";
        case EKSourceTypeSubscribed: return @"Subscribed";
        case EKSourceTypeBirthdays: return @"Birthdays";
        default: return @"Other";
    }
}

// 获取事件列表
- (nullable NSArray<PlatformItem *> *)getEventsCalendarId:(NSString *)calendarId startMs:(NSNumber *)startMs endMs:(NSNumber *)endMs error:(FlutterError *_Nullable *_Nonnull)error {
    NSMutableArray<PlatformItem *> *items = [NSMutableArray array];

    EKCalendar *calendar = [self.eventStore calendarWithIdentifier:calendarId];
    if (!calendar) return @[];

    NSDate *startDate = [NSDate dateWithTimeIntervalSince1970:(startMs.longLongValue / 1000.0)];
    NSDate *endDate = [NSDate dateWithTimeIntervalSince1970:(endMs.longLongValue / 1000.0)];

    NSPredicate *predicate = [self.eventStore predicateForEventsWithStartDate:startDate endDate:endDate calendars:@[calendar]];
    NSArray<EKEvent *> *events = [self.eventStore eventsMatchingPredicate:predicate];

    for (EKEvent *event in events) {
        PlatformItem *item = [[PlatformItem alloc] init];
        item.localId = event.eventIdentifier;

        // 🚀 核心改动：优先使用系统的 externalIdentifier (通常是原生的 UUID)
        item.uid = event.calendarItemExternalIdentifier ?: event.eventIdentifier;

        item.title = event.title;
        item.notes = event.notes;
        item.startTime = @([event.startDate timeIntervalSince1970] * 1000);
        item.endTime = @([event.endDate timeIntervalSince1970] * 1000);
        item.lastModified = @([event.lastModifiedDate timeIntervalSince1970] * 1000);
        item.isAllDay = @(event.isAllDay);
        item.isTask = @NO;

        [items addObject:item];
    }
    return items;
}

// 创建事件（支持传入外部生成的 UID）
- (void)createEventCalendarId:(NSString *)calendarId title:(NSString *)title start:(NSNumber *)start end:(NSNumber *)end notes:(nullable NSString *)notes uid:(nullable NSString *)uid completion:(void (^)(NSString *_Nullable, FlutterError *_Nullable))completion {

    EKCalendar *calendar = [self.eventStore calendarWithIdentifier:calendarId];
    if (!calendar) {
        completion(nil, [FlutterError errorWithCode:@"NOT_FOUND" message:@"Calendar not found" details:nil]);
        return;
    }

    EKEvent *event = [EKEvent eventWithEventStore:self.eventStore];
    event.calendar = calendar;
    event.title = title;
    event.notes = notes;
    event.startDate = [NSDate dateWithTimeIntervalSince1970:(start.longLongValue / 1000.0)];
    event.endDate = [NSDate dateWithTimeIntervalSince1970:(end.longLongValue / 1000.0)];

    // 注意：iOS 系统的 calendarItemExternalIdentifier 是只读的，主要由同步句柄维护。
    // 如果要在推送时严格匹配，建议在本地数据库中记录映射关系。

    NSError *saveError;
    BOOL success = [self.eventStore saveEvent:event span:EKSpanThisEvent commit:YES error:&saveError];

    if (success) {
        completion(event.eventIdentifier, nil);
    } else {
        completion(nil, [FlutterError errorWithCode:@"SAVE_ERROR" message:saveError.localizedDescription details:nil]);
    }
}

// 获取所有系统事件 ID
- (nullable NSArray<NSString *> *)getSystemEventIdsCalendarId:(NSString *)calendarId error:(FlutterError *_Nullable *_Nonnull)error {
    EKCalendar *calendar = [self.eventStore calendarWithIdentifier:calendarId];
    if (!calendar) return @[];

    // iOS 无法直接查询全量 ID，通常需要给一个较宽的时间范围（如前后一年）
    NSDate *now = [NSDate date];
    NSDate *startDate = [now dateByAddingTimeInterval:-365*24*3600];
    NSDate *endDate = [now dateByAddingTimeInterval:365*24*3600];

    NSPredicate *predicate = [self.eventStore predicateForEventsWithStartDate:startDate endDate:endDate calendars:@[calendar]];
    NSArray<EKEvent *> *events = [self.eventStore eventsMatchingPredicate:predicate];

    NSMutableArray *ids = [NSMutableArray array];
    for (EKEvent *e in events) {
        [ids addObject:e.eventIdentifier];
    }
    return ids;
}

// 删除事件
- (void)deleteEventEventId:(NSString *)eventId completion:(void (^)(NSNumber *_Nullable, FlutterError *_Nullable))completion {
    EKEvent *event = [self.eventStore eventWithIdentifier:eventId];
    if (!event) {
        completion(@NO, nil);
        return;
    }

    NSError *error;
    BOOL success = [self.eventStore removeEvent:event span:EKSpanThisEvent commit:YES error:&error];
    completion(@(success), error ? [FlutterError errorWithCode:@"DELETE_ERROR" message:error.localizedDescription details:nil] : nil);
}

@end