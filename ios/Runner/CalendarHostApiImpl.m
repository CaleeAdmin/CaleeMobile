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

- (void)requestPermissionForTask:(BOOL)forTask completion:(void (^)(NSNumber *_Nullable, FlutterError *_Nullable))completion {
    // iOS使用统一的日历权限，forTask参数在这里不使用
    [self.eventStore requestAccessToEntityType:EKEntityTypeEvent completion:^(BOOL granted, NSError * _Nullable error) {
        if (error) {
            completion(nil, [FlutterError errorWithCode:@"PERMISSION_ERROR"
                                                message:error.localizedDescription
                                                details:nil]);
        } else {
            completion(@(granted), nil);
        }
    }];
}

- (nullable NSArray<PlatformCalendar *> *)getCalendarsWithError:(FlutterError *_Nullable *_Nonnull)error {
    NSMutableArray<PlatformCalendar *> *calendars = [NSMutableArray array];

    // 检查权限
    EKAuthorizationStatus status = [EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent];
    if (status != EKAuthorizationStatusAuthorized) {
        *error = [FlutterError errorWithCode:@"PERMISSION_DENIED"
                                     message:@"Calendar access not authorized"
                                     details:nil];
        return nil;
    }

    // 获取所有日历
    NSArray<EKCalendar *> *ekCalendars = [self.eventStore calendarsForEntityType:EKEntityTypeEvent];

    for (EKCalendar *ekCalendar in ekCalendars) {
        // 转换颜色为十六进制字符串
        UIColor *color = [UIColor colorWithCGColor:ekCalendar.CGColor];
        CGFloat red, green, blue, alpha;
        [color getRed:&red green:&green blue:&blue alpha:&alpha];
        NSString *colorHex = [NSString stringWithFormat:@"#%02X%02X%02X",
                             (int)(red * 255), (int)(green * 255), (int)(blue * 255)];

        PlatformCalendar *calendar = [[PlatformCalendar alloc] init];
        calendar.id = ekCalendar.calendarIdentifier;
        calendar.name = ekCalendar.title;
        calendar.color = colorHex;
        calendar.isReadOnly = @(!ekCalendar.allowsContentModifications);
        calendar.supportsEvents = @(ekCalendar.supportedEventAvailabilities & EKCalendarEventAvailabilityBusy);
        calendar.supportsTasks = @NO; // iOS EventKit 主要支持事件，不直接支持任务

        [calendars addObject:calendar];
    }

    return [calendars copy];
}

- (nullable NSArray<PlatformItem *> *)getItemsCalendarId:(NSString *)calendarId startMs:(NSNumber *)startMs endMs:(NSNumber *)endMs error:(FlutterError *_Nullable *_Nonnull)error {
    NSMutableArray<PlatformItem *> *items = [NSMutableArray array];

    // 检查权限
    EKAuthorizationStatus status = [EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent];
    if (status != EKAuthorizationStatusAuthorized) {
        *error = [FlutterError errorWithCode:@"PERMISSION_DENIED"
                                     message:@"Calendar access not authorized"
                                     details:nil];
        return nil;
    }

    // 获取指定日历
    EKCalendar *calendar = [self.eventStore calendarWithIdentifier:calendarId];
    if (!calendar) {
        *error = [FlutterError errorWithCode:@"CALENDAR_NOT_FOUND"
                                     message:@"Calendar not found"
                                     details:nil];
        return nil;
    }

    // 创建时间范围
    NSDate *startDate = [NSDate dateWithTimeIntervalSince1970:(startMs.longLongValue / 1000.0)];
    NSDate *endDate = [NSDate dateWithTimeIntervalSince1970:(endMs.longLongValue / 1000.0)];

    // 创建谓词
    NSPredicate *predicate = [self.eventStore predicateForEventsWithStartDate:startDate
                                                                       endDate:endDate
                                                                     calendars:@[calendar]];

    // 获取事件
    NSArray<EKEvent *> *events = [self.eventStore eventsMatchingPredicate:predicate];

    for (EKEvent *event in events) {
        PlatformItem *item = [[PlatformItem alloc] init];
        item.localId = event.eventIdentifier;
        item.uid = event.eventIdentifier; // 使用本地ID作为UID
        item.title = event.title;
        item.notes = event.notes;
        item.location = event.location;
        item.startTime = @([event.startDate timeIntervalSince1970] * 1000);
        item.endTime = @([event.endDate timeIntervalSince1970] * 1000);
        item.lastModified = @([event.lastModifiedDate timeIntervalSince1970] * 1000);
        item.isTask = @NO; // EventKit 主要是事件
        item.isAllDay = @(event.isAllDay);
        item.status = @1; // 假设状态为确认
        item.priority = nil;

        [items addObject:item];
    }

    return [items copy];
}

- (void)upsertItemCalendarId:(NSString *)calendarId item:(PlatformItem *)item completion:(void (^)(NSString *_Nullable, FlutterError *_Nullable))completion {
    // 检查权限
    EKAuthorizationStatus status = [EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent];
    if (status != EKAuthorizationStatusAuthorized) {
        completion(nil, [FlutterError errorWithCode:@"PERMISSION_DENIED"
                                           message:@"Calendar access not authorized"
                                           details:nil]);
        return;
    }

    // 获取指定日历
    EKCalendar *calendar = [self.eventStore calendarWithIdentifier:calendarId];
    if (!calendar) {
        completion(nil, [FlutterError errorWithCode:@"CALENDAR_NOT_FOUND"
                                           message:@"Calendar not found"
                                           details:nil]);
        return;
    }

    EKEvent *event;
    if (item.localId && item.localId.length > 0) {
        // 更新现有事件
        event = [self.eventStore eventWithIdentifier:item.localId];
        if (!event) {
            completion(nil, [FlutterError errorWithCode:@"EVENT_NOT_FOUND"
                                               message:@"Event not found"
                                               details:nil]);
            return;
        }
    } else {
        // 创建新事件
        event = [EKEvent eventWithEventStore:self.eventStore];
        event.calendar = calendar;
    }

    // 设置事件属性
    event.title = item.title ?: @"";
    event.notes = item.notes;
    event.location = item.location;

    if (item.startTime && item.endTime) {
        event.startDate = [NSDate dateWithTimeIntervalSince1970:(item.startTime.longLongValue / 1000.0)];
        event.endDate = [NSDate dateWithTimeIntervalSince1970:(item.endTime.longLongValue / 1000.0)];
    }

    event.allDay = item.isAllDay.boolValue;

    // 保存事件
    NSError *saveError;
    BOOL success = [self.eventStore saveEvent:event span:EKSpanThisEvent commit:YES error:&saveError];

    if (success) {
        completion(event.eventIdentifier, nil);
    } else {
        completion(nil, [FlutterError errorWithCode:@"SAVE_ERROR"
                                           message:saveError.localizedDescription ?: @"Failed to save event"
                                           details:nil]);
    }
}

- (void)deleteItemLocalId:(NSString *)localId completion:(void (^)(FlutterError *_Nullable))completion {
    // 检查权限
    EKAuthorizationStatus status = [EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent];
    if (status != EKAuthorizationStatusAuthorized) {
        completion([FlutterError errorWithCode:@"PERMISSION_DENIED"
                                      message:@"Calendar access not authorized"
                                      details:nil]);
        return;
    }

    // 获取事件
    EKEvent *event = [self.eventStore eventWithIdentifier:localId];
    if (!event) {
        completion([FlutterError errorWithCode:@"EVENT_NOT_FOUND"
                                      message:@"Event not found"
                                      details:nil]);
        return;
    }

    // 删除事件
    NSError *deleteError;
    BOOL success = [self.eventStore removeEvent:event span:EKSpanThisEvent commit:YES error:&deleteError];

    if (success) {
        completion(nil);
    } else {
        completion([FlutterError errorWithCode:@"DELETE_ERROR"
                                      message:deleteError.localizedDescription ?: @"Failed to delete event"
                                      details:nil]);
    }
}

@end
