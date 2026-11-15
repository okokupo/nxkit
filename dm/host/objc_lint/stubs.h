// Minimal ObjC/CoreBluetooth syntax-lint stubs for clang -fsyntax-only on Linux.
// Purpose: catch syntax + type errors BEFORE the 7-minute cloud build round-trip.
// NOT semantic truth — declarations mirror only what dm/host/*.m actually use.
#ifndef DM_OBJC_LINT_STUBS_H
#define DM_OBJC_LINT_STUBS_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>

typedef unsigned long NSUInteger;
typedef unsigned short unichar;
typedef signed long NSInteger;
typedef signed char BOOL;
#define YES ((BOOL)1)
#define NO ((BOOL)0)
#define nil (0)
#define Nil (0)
typedef struct { NSUInteger location, length; } NSRange;
#define MIN(a,b) (((a)<(b))?(a):(b))
typedef struct os_unfair_lock_s os_unfair_lock, *os_unfair_lock_t;
struct os_unfair_lock_s { uint32_t _o[4]; };
#define OS_UNFAIR_LOCK_INIT {._o = {0,}}
void os_unfair_lock_lock(os_unfair_lock *l);
void os_unfair_lock_unlock(os_unfair_lock *l);

// ---- Foundation ----
@interface NSObject
+ (instancetype)new;
+ (instancetype)alloc;
- (instancetype)init;
@end
@interface NSString : NSObject
@property (readonly) NSUInteger length;
- (NSUInteger)length;
- (BOOL)hasPrefix:(NSString *)s;
- (BOOL)hasSuffix:(NSString *)s;
- (BOOL)containsString:(NSString *)s;
- (NSString *)lowercaseString;
- (NSString *)stringByAppendingString:(NSString *)s;
- (BOOL)isEqualToString:(NSString *)s;
- (NSString *)substringToIndex:(NSUInteger)i;
- (NSString *)substringFromIndex:(NSUInteger)i;
- (unichar)characterAtIndex:(NSUInteger)i;
- (const char *)UTF8String;
- (instancetype)appendFormat:(NSString *)fmt, ...;
- (instancetype)appendString:(NSString *)s;
- (instancetype)componentsJoinedByString:(NSString *)sep;
+ (instancetype)stringWithString:(NSString *)s;
+ (instancetype)stringWithFormat:(NSString *)fmt, ...;
@end
@interface NSMutableString : NSString @end
@interface NSData : NSObject
@property (readonly) NSUInteger length;
- (const void *)bytes;
- (NSData *)subdataWithRange:(NSRange)range;
- (NSString *)description;
- (double)doubleValue;
- (float)floatValue;
- (int)intValue;
- (void)appendData:(NSData *)d;
+ (instancetype)dataWithBytes:(const void *)b length:(NSUInteger)len;
+ (instancetype)data;
@end
@interface NSMutableData : NSData
+ (instancetype)dataWithCapacity:(NSUInteger)cap;
@end
@interface NSArray<__covariant ObjectType> : NSObject
@property (readonly) NSUInteger count;
- (id)objectAtIndex:(NSUInteger)i;
- (id)firstObject;
- (NSString *)componentsJoinedByString:(NSString *)sep;
+ (instancetype)arrayWithObjects:(const id [])objs count:(NSUInteger)cnt;
- (id)objectAtIndexedSubscript:(NSUInteger)i;
@end
@interface NSMutableArray<__covariant ObjectType> : NSArray
- (void)addObject:(id)o;
- (void)removeAllObjects;
- (void)removeObject:(id)o;
- (void)removeObjectAtIndex:(NSUInteger)i;
- (void)removeLastObject;
- (void)insertObject:(id)o atIndex:(NSUInteger)i;
@end
@interface NSDictionary<__covariant KeyType, __covariant ObjectType> : NSObject
- (id)objectForKeyedSubscript:(id)key;
- (NSArray *)allKeys;
- (NSArray *)allValues;
+ (instancetype)dictionaryWithObjects:(const id [])objs forKeys:(const id [])keys count:(NSUInteger)cnt;
@end
@interface NSTimer : NSObject
+ (NSTimer *)scheduledTimerWithTimeInterval:(double)t target:(id)tgt selector:(SEL)sel userInfo:(id)ui repeats:(BOOL)r;
+ (NSTimer *)scheduledTimerWithTimeInterval:(double)t repeats:(BOOL)r block:(void (^)(NSTimer *))block;
+ (NSTimer *)timerWithTimeInterval:(double)t repeats:(BOOL)r block:(void (^)(NSTimer *))block;
- (void)invalidate;
@end
@interface NSUserDefaults : NSObject
+ (NSUserDefaults *)standardUserDefaults;
- (id)objectForKey:(NSString *)k;
- (void)setObject:(id)v forKey:(NSString *)k;
- (void)removeObjectForKey:(NSString *)k;
- (NSArray *)arrayForKey:(NSString *)k;
- (NSInteger)integerForKey:(NSString *)k;
- (void)setInteger:(NSInteger)v forKey:(NSString *)k;
- (BOOL)boolForKey:(NSString *)k;
- (void)setBool:(BOOL)v forKey:(NSString *)k;
- (double)doubleForKey:(NSString *)k;
- (void)setDouble:(double)v forKey:(NSString *)k;
@end
static inline NSRange NSMakeRange(NSUInteger loc, NSUInteger len) { NSRange r; r.location = loc; r.length = len; return r; }
@interface NSMutableDictionary<KeyType, ObjectType> : NSDictionary
- (void)setObject:(id)o forKeyedSubscript:(id)key;
- (void)removeObjectForKey:(id)k;
@end
@interface NSError : NSObject
@property (readonly, copy) NSString *localizedDescription;
@end
@interface NSUUID : NSObject
@property (readonly, copy) NSString *UUIDString;
@end
// ---- GCD (enough for syntax) ----
typedef struct dispatch_queue_s *dispatch_queue_t;
void dispatch_after(int64_t when, dispatch_queue_t q, void (^block)(void));
int64_t dispatch_time(int64_t when, int64_t delta);
dispatch_queue_t dispatch_get_main_queue(void);
#define NSEC_PER_SEC 1000000000ull
#define DISPATCH_TIME_NOW 0ll
@interface NSDate : NSObject
@property (readonly) double timeIntervalSinceNow;
+ (instancetype)date;
@end
@interface NSSet<__covariant ObjectType> : NSObject
@property (readonly) NSUInteger count;
- (NSArray *)allObjects;
@end
@interface NSMutableSet<ObjectType> : NSSet
- (void)addObject:(id)o;
- (void)removeAllObjects;
- (BOOL)containsObject:(id)o;
@end

// ---- CoreBluetooth ----
@interface CBExternalKey : NSString @end
extern CBExternalKey *CBCentralManagerScanOptionAllowDuplicatesKey;
#define DISPATCH_TIME_NOW 0ll
@interface NSBundle : NSObject
+ (NSBundle *)mainBundle;
- (id)objectForInfoDictionaryKey:(NSString *)k;
- (NSString *)pathForResource:(NSString *)name ofType:(NSString *)ext;
@end
@interface NSNumber : NSObject
+ (instancetype)numberWithInt:(int)v;
+ (instancetype)numberWithLong:(long)v;
+ (instancetype)numberWithInteger:(long)v;
+ (instancetype)numberWithUnsignedInteger:(unsigned long)v;
+ (instancetype)numberWithFloat:(float)v;
+ (instancetype)numberWithDouble:(double)v;
+ (instancetype)numberWithBool:(BOOL)v;
- (int)intValue;
- (NSUInteger)unsignedIntegerValue;
@end
@interface CBUUID : NSObject
@property (readonly, copy) NSString *UUIDString;
- (BOOL)isEqual:(id)o;
+ (instancetype)UUIDWithString:(NSString *)s;
@end
typedef enum CBManagerState : int { CBManagerStateUnknown=0, CBManagerStateResetting, CBManagerStateUnsupported, CBManagerStateUnauthorized, CBManagerStatePoweredOff, CBManagerStatePoweredOn } CBManagerState;
extern CBExternalKey *CBAdvertisementDataLocalNameKey;
extern CBExternalKey *CBAdvertisementDataManufacturerDataKey;
extern CBExternalKey *CBAdvertisementDataServiceUUIDsKey;
extern CBExternalKey *CBAdvertisementDataOverflowServiceUUIDsKey;
enum { CBCharacteristicPropertyRead=1, CBCharacteristicPropertyWriteWithoutResponse=2, CBCharacteristicPropertyWrite=4, CBCharacteristicPropertyNotify=16 };
typedef enum CBCharacteristicWriteType : int { CBCharacteristicWriteWithResponse=0, CBCharacteristicWriteWithoutResponse } CBCharacteristicWriteType;
@class CBService, CBCharacteristic;
@protocol CBPeripheralDelegate @end
@protocol CBCentralManagerDelegate @end
@interface CBAttribute : NSObject
@property (readonly, copy) CBUUID *UUID;
- (BOOL)isEqual:(id)o;
@end
@interface CBService : CBAttribute
@property (readonly) NSArray<CBCharacteristic *> *characteristics;
@end
@interface CBCharacteristic : CBAttribute
@property (readonly, copy) NSData *value;
@property (readonly) NSUInteger properties;
@property (readonly, retain) CBService *service;
@end
@interface CBPeer : NSObject
@property (readonly, copy) NSUUID *identifier;
@property (readonly, copy) NSString *name;
@end
@interface CBPeripheral : CBPeer
@property (retain) id<CBPeripheralDelegate> delegate;
@property (readonly) NSArray<CBService *> *services;
@property (readonly) int state;
@property (readonly) BOOL canSendWriteWithoutResponse;
- (void)discoverServices:(NSArray *)s;
- (void)discoverCharacteristics:(NSArray *)c forService:(CBService *)svc;
- (void)setNotifyValue:(BOOL)v forCharacteristic:(CBCharacteristic *)c;
- (void)writeValue:(NSData *)d forCharacteristic:(CBCharacteristic *)c type:(CBCharacteristicWriteType)t;
- (void)readValueForCharacteristic:(CBCharacteristic *)c;
- (NSInteger)maximumWriteValueLengthForType:(CBCharacteristicWriteType)t;
@end
typedef enum CBPeripheralState : int { CBPeripheralStateDisconnected=0, CBPeripheralStateConnecting, CBPeripheralStateConnected, CBPeripheralStateDisconnecting } CBPeripheralState;
#define NSEC_PER_MSEC 1000000ull
@interface CBCentralManager : NSObject
@property (readonly) CBManagerState state;
- (instancetype)initWithDelegate:(id<CBCentralManagerDelegate>)d queue:(dispatch_queue_t)q options:(NSDictionary *)o;
- (instancetype)initWithDelegate:(id<CBCentralManagerDelegate>)d queue:(dispatch_queue_t)q;
- (void)scanForPeripheralsWithServices:(NSArray *)s options:(NSDictionary *)o;
- (void)stopScan;
- (void)connectPeripheral:(CBPeripheral *)p options:(NSDictionary *)o;
- (void)cancelPeripheralConnection:(CBPeripheral *)p;
@end

#endif
