//
//  DWDatabase.m
//  DWDatabase
//
//  Created by Wicky on 2018/6/9.
//  Copyright © 2018年 Wicky. All rights reserved.
//

#import "DWDatabase.h"
#import <Foundation/NSZone.h>
#import "NSObject+PropertyInfo.h"
#import "DWDatabaseConditionMaker.h"
#import "DWDatabaseMacro.h"


#pragma mark --------- 数据库管理模型部分开始 ---------
@interface DWDatabaseInfo : NSObject<DWDatabaseSaveProtocol>

@property (nonatomic ,copy) NSString * dbName;

@property (nonatomic ,copy) NSString * dbPath;

@property (nonatomic ,copy) NSString * relativePath;

///-1初始值，0沙盒，1bundle，2其他
@property (nonatomic ,assign) int relativeType;

@end

@implementation DWDatabaseInfo

+(NSArray *)dw_DataBaseWhiteList {
    static NSArray * wl = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        wl = @[@"dbName",@"relativePath",@"relativeType"];
    });
    return wl;
}

///用于存表过程
-(BOOL)configRelativePath {
    if (!self.dbPath.length) {
        return NO;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.dbPath]) {
        return NO;
    }
    if ([self.dbPath hasPrefix:NSHomeDirectory()]) {
        self.relativeType = 0;
        self.relativePath = [self.dbPath stringByReplacingOccurrencesOfString:NSHomeDirectory() withString:@""];
    } else if ([self.dbPath hasPrefix:[NSBundle mainBundle].bundlePath]) {
        self.relativeType = 1;
        self.relativePath = [self.dbPath stringByReplacingOccurrencesOfString:[NSBundle mainBundle].bundlePath withString:@""];
    } else {
        self.relativeType = 2;
        self.relativePath = self.dbPath;
    }
    return YES;
}

///用于取表过程
-(BOOL)configDBPath {
    if (!self.relativePath.length) {
        return NO;
    }
    if (self.relativeType == 0) {
        self.dbPath = [NSHomeDirectory() stringByAppendingString:self.relativePath];
    } else if (self.relativeType == 1) {
        self.dbPath = [[NSBundle mainBundle].bundlePath stringByAppendingString:self.relativePath];
    } else if (self.relativeType == 2) {
        self.dbPath = self.relativePath;
    } else {
        return NO;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.dbPath]) {
        return NO;
    }
    return YES;
}

#pragma mark --- override ---
-(instancetype)init {
    if (self = [super init]) {
        _relativeType = -1;
    }
    return self;
}

@end
#pragma mark --------- 数据库管理模型部分结束 ---------

#pragma mark --------- DWDatabaseConfiguration开始 ---------
@implementation DWDatabaseConfiguration

-(instancetype)initWithName:(NSString *)name tblName:(NSString * )tblName dbq:(FMDatabaseQueue *)dbq {
    if (self = [super init]) {
        _dbName = name;
        _tableName = tblName;
        _dbQueue = dbq;
    }
    return self;
}

-(NSString *)dbPath {
    return self.dbQueue.path;
}

@end
#pragma mark --------- DWDatabaseConfiguration结束 ---------

#pragma mark --------- DWDatabaseSQLFactory开始 ---------
@interface DWDatabaseSQLFactory : NSObject

@property (nonatomic ,strong) NSArray * args;

@property (nonatomic ,copy) NSString * sql;

@property (nonatomic ,strong) NSObject * model;

@end

@implementation DWDatabaseSQLFactory

@end
#pragma mark --------- DWDatabaseSQLFactory结束 ---------

#pragma mark --------- DWDatabase开始 ---------

#define kSqlSetTblName (@"sql_set")
#define kCreatePrefix (@"c")
#define kInsertPrefix (@"i")
#define kDeletePrefix (@"d")
#define kUpdatePrefix (@"u")
#define kQueryPrefix (@"q")
static const char * kAdditionalConfKey = "kAdditionalConfKey";
static NSString * const kDwIdKey = @"kDwIdKey";
static void* dbOpQKey = "dbOperationQueueKey";

@interface DWDatabase ()

///数据库路径缓存，缓存当前所有数据库路径
@property (nonatomic ,strong) NSMutableDictionary * allDBs_prv;

///当前使用过的数据库的FMDatabaseQueue的容器
@property (nonatomic ,strong) NSMutableDictionary <NSString *,FMDatabaseQueue *>* dbqContainer;

///私有FMDatabaseQueue，用于读取或更新本地表配置，于 -initializeDBWithError: 时被赋值
@property (nonatomic ,strong) FMDatabaseQueue * privateQueue;

///每个类对应的存表的键值缓存
@property (nonatomic ,strong) NSMutableDictionary * saveKeysCache;

///每个类对应的存表的属性信息缓存
@property (nonatomic ,strong) NSMutableDictionary * saveInfosCache;

///插入语句缓存
@property (nonatomic ,strong) NSMutableDictionary * sqlsCache;

///是否成功配置过的标志位
@property (nonatomic ,assign) BOOL hasInitialize;

@property (nonatomic ,strong) dispatch_queue_t dbOperationQueue;

@end

///数据库类
@implementation DWDatabase

#pragma mark --- interface method ---
-(BOOL)initializeDBWithError:(NSError *__autoreleasing *)error {
    if (self.hasInitialize) {
        return YES;
    }
    ///首次启动时还没有沙盒地址，此时需要调用一下才能创建出来
    if (![[NSFileManager defaultManager] fileExistsAtPath:defaultSavePath()]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:defaultSavePath() withIntermediateDirectories:NO attributes:nil error:nil];
    }
    
    ///私有表地址（用于存储数据库信息）
    NSString * savePath = [defaultSavePath() stringByAppendingPathComponent:@".private/privateInfo.sqlite"];
    self.privateQueue = [self openDBQueueWithName:nil path:savePath private:YES];
    if (!self.privateQueue) {
        NSError * err = errorWithMessage(@"Invalid path which FMDatabaseQueue could not open.", 10003);
        safeLinkError(error, err);
        return NO;
    }
    BOOL success = [self dw_createTableWithClass:[DWDatabaseInfo class] tableName:kSqlSetTblName inQueue:self.privateQueue error:error];
    NSArray <DWDatabaseInfo *>* res = [self dw_queryTableWithTableName:kSqlSetTblName keys:nil limit:0 offset:0 orderKey:nil ascending:YES inQueue:self.privateQueue error:error condition:^(DWDatabaseConditionMaker *maker) {
        maker.loadClass([DWDatabaseInfo class]);
    }];
    
    if (res.count) {
        ///取出以后配置数据库完整地址
        [res enumerateObjectsUsingBlock:^(DWDatabaseInfo * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            if ([obj configDBPath] && obj.dbPath.length && obj.dbName.length) {
                [self.allDBs_prv setValue:obj.dbPath forKey:obj.dbName];
            }
        }];
    }
    if (success) {
        self.hasInitialize = YES;
    }
    return success;
}

-(DWDatabaseConfiguration *)fetchDBConfigurationAutomaticallyWithClass:(Class)cls name:(NSString *)name tableName:(NSString *)tblName path:(NSString *)path error:(NSError *__autoreleasing *)error {
    if (![self initializeDBWithError:error]) {
        return nil;
    }
    if (![self configDBIfNeededWithClass:cls name:name tableName:tblName path:path error:error]) {
        return nil;
    }
    DWDatabaseConfiguration * conf = [self fetchDBConfigurationWithName:name tabelName:tblName error:error];
    BOOL valid = [self validateConfiguration:conf considerTableName:YES error:error];
    if (!valid) {
        return nil;
    }
    return conf;
}

-(BOOL)configDBIfNeededWithClass:(Class)cls name:(NSString *)name tableName:(NSString *)tblName path:(NSString *)path error:(NSError *__autoreleasing *)error {
    if (cls == Nil || !tblName.length) {
        return NO;
    }
    BOOL success = [self configDBIfNeededWithName:name path:path error:error];
    if (!success) {
        return NO;
    }
    DWDatabaseConfiguration * conf = [self fetchDBConfigurationWithName:name error:error];
    success = [self validateConfiguration:conf considerTableName:NO error:error];
    if (!success) {
        return NO;
    }
    BOOL exist = [self isTableExistWithTableName:tblName configuration:conf error:error];
    if (exist) {
        return YES;
    }
    return [self createTableWithClass:cls tableName:tblName configuration:conf error:error];
}

-(BOOL)insertTableAutomaticallyWithModel:(NSObject *)model name:(NSString *)name tableName:(NSString *)tblName path:(NSString *)path keys:(NSArray<NSString *> *)keys error:(NSError *__autoreleasing *)error {
    DWDatabaseConfiguration * conf = [self fetchDBConfigurationAutomaticallyWithClass:[model class] name:name tableName:tblName path:path error:error];
    if (!conf) {
        return NO;
    }
    [self supplyFieldIfNeededWithModel:model configuration:conf error:error];
    return [self dw_insertTableWithModel:model tableName:tblName keys:keys inQueue:conf.dbQueue error:error];
}

-(BOOL)deleteTableAutomaticallyWithModel:(NSObject *)model name:(NSString *)name tableName:(NSString *)tblName path:(NSString *)path byDw_id:(BOOL)byID keys:(NSArray<NSString *> *)keys error:(NSError *__autoreleasing *)error {
    DWDatabaseConfiguration * conf = [self fetchDBConfigurationAutomaticallyWithClass:[model class] name:name tableName:tblName path:path error:error];
    if (!conf) {
        return NO;
    }
    return [self dw_deleteTableWithModel:model tableName:tblName byDw_id:byID keys:keys inQueue:conf.dbQueue error:error];
}

-(BOOL)updateTableAutomaticallyWithModel:(NSObject *)model name:(NSString *)name tableName:(NSString *)tblName path:(NSString *)path keys:(NSArray<NSString *> *)keys error:(NSError *__autoreleasing *)error {
    DWDatabaseConfiguration * conf = [self fetchDBConfigurationAutomaticallyWithClass:[model class] name:name tableName:tblName path:path error:error];
    if (!conf) {
        return NO;
    }
    [self supplyFieldIfNeededWithModel:model configuration:conf error:error];
    return [self dw_updateTableWithModel:model tableName:tblName keys:keys inQueue:conf.dbQueue error:error];
}

-(NSArray<NSObject *> *)queryTableAutomaticallyWithModel:(NSObject *)model name:(NSString *)name tableName:(NSString *)tblName path:(NSString *)path keys:(NSArray *)keys error:(NSError *__autoreleasing *)error condition:(void (^)(DWDatabaseConditionMaker *))condition {
    DWDatabaseConfiguration * conf = [self fetchDBConfigurationAutomaticallyWithClass:[model class] name:name tableName:tblName path:path error:error];
    if (!conf) {
        return nil;
    }
    if (!condition) {
        condition = ^(DWDatabaseConditionMaker * maker) {
            maker.loadClass([model class]);
        };
    }
    return [self dw_queryTableWithTableName:conf.tableName keys:keys limit:0 offset:0 orderKey:nil ascending:YES inQueue:conf.dbQueue error:error condition:condition];
}

///配置数据库
-(BOOL)configDBIfNeededWithName:(NSString *)name path:(NSString *)path error:(NSError * __autoreleasing *)error {
    if (!name.length) {
        NSError * err = errorWithMessage(@"Invalid name whose length is 0.", 10000);
        safeLinkError(error, err);
        return NO;
    }
    if ([self.allDBs_prv.allKeys containsObject:name]) {
        NSError * err = errorWithMessage(@"Invalid name which there's already an database with it.If you are sure to use this name with a new database,delete the old one first.", 10001);
        safeLinkError(error,err);
        return YES;
    }
    if (!path.length) {
        path = [[defaultSavePath() stringByAppendingPathComponent:generateUUID()] stringByAppendingPathExtension:@"sqlite3"];
    }
    
    FMDatabaseQueue * q = [self openDBQueueWithName:name path:path private:NO];
    BOOL success = (q != nil);
    ///创建数据库，若成功则保存
    if (!success) {
        NSError * err = errorWithMessage(@"Invalid path which FMDatabaseQueue could not open.", 10003);
        safeLinkError(error, err);
        return NO;
    }
    
    DWDatabaseInfo * info = [DWDatabaseInfo new];
    info.dbName = name;
    info.dbPath = path;
    if ([info configRelativePath]) {
        [self dw_insertTableWithModel:info tableName:kSqlSetTblName keys:nil inQueue:self.privateQueue error:error];
    } else {
        success = NO;
    }
    return success;
}

-(BOOL)deleteDBWithName:(NSString *)name error:(NSError *__autoreleasing *)error {
    if (!name.length) {
        NSError * err = errorWithMessage(@"Invalid name whose length is 0.", 10000);
        safeLinkError(error, err);
        return NO;
    }
    if (![self.allDBs.allKeys containsObject:name]) {
        NSError * err = errorWithMessage(@"Invalid name which there's no database named with it.", 10002);
        safeLinkError(error,err);
        return NO;
    }
    
    BOOL success = NO;
    
    ///移除管理表、缓存及数据库
    NSString * path = [self.allDBs valueForKey:name];
    DWDatabaseInfo * info = [DWDatabaseInfo new];
    info.dbName = name;
    info.dbPath = path;
    if ([info configRelativePath]) {
        success = [self dw_deleteTableWithModel:info tableName:kSqlSetTblName byDw_id:NO keys:nil inQueue:self.privateQueue error:error];
        ///若表删除成功，应移除所有相关信息，包括缓存的DBQ，数据库地址缓存，本地数据库文件，以及若为当前库还要清空当前库信息
        if (success) {
            [self.allDBs_prv removeObjectForKey:name];
            [self.dbqContainer removeObjectForKey:name];
            success = [[NSFileManager defaultManager] removeItemAtPath:path error:error];
        }
    }
    return success;
}

-(DWDatabaseConfiguration *)fetchDBConfigurationWithName:(NSString *)name error:(NSError *__autoreleasing *)error {
    if (!name.length) {
        NSError * err = errorWithMessage(@"Invalid name whose length is 0.", 10000);
        safeLinkError(error, err);
        return nil;
    }
    FMDatabaseQueue *dbqTmp = nil;
    ///内存总存在的DB直接切换
    if ([self.dbqContainer.allKeys containsObject:name]) {
        dbqTmp = [self.dbqContainer valueForKey:name];
    }
    ///内存中寻找DB路径，若存在则初始化DB
    if (!dbqTmp && [self.allDBs_prv.allKeys containsObject:name]) {
        NSString * path = [self.allDBs_prv valueForKey:name];
        if (path.length) {
            dbqTmp = [self openDBQueueWithName:name path:path private:NO];
        }
    }
    if (!dbqTmp) {
        NSError * err = errorWithMessage(@"Can't not fetch a FMDatabaseQueue", 10004);
        safeLinkError(error, err);
        return nil;
    }
    return [[DWDatabaseConfiguration alloc] initWithName:name tblName:nil dbq:dbqTmp];
}

-(BOOL)isTableExistWithTableName:(NSString *)tblName configuration:(DWDatabaseConfiguration *)conf error:(NSError * __autoreleasing *)error {
    __block BOOL exist = NO;
    excuteOnDBOperationQueue(self, ^{
        [conf.dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
            exist = [db tableExists:tblName];
        }];
    });
    if (!exist) {
        NSError * err = errorWithMessage(@"Invalid tabelName which currentDB doesn't contains a table named it.", 10006);
        safeLinkError(error, err);
        return NO;
    }
    return exist;
}

-(NSArray<NSString *> *)queryAllTableNamesInDBWithConfiguration:(DWDatabaseConfiguration *)conf error:(NSError *__autoreleasing *)error {
    
    BOOL valid = [self validateConfiguration:conf considerTableName:NO error:error];
    if (!valid) {
        return nil;
    }
    
    FMResultSet * set = [self queryTableWithSQL:@"SELECT name FROM sqlite_master WHERE type='table' ORDER BY name" configuration:conf error:error];
    NSMutableArray * arr = [NSMutableArray arrayWithCapacity:0];
    while ([set next]) {
        NSString * tblName = [set stringForColumn:@"name"];
        if (tblName.length) {
            [arr addObject:tblName];
        }
    }
    [set close];
    
    if ([arr containsObject:@"sqlite_sequence"]) {
        [arr removeObject:@"sqlite_sequence"];
    }
    return arr;
}

-(BOOL)createTableWithClass:(Class)cls tableName:(NSString *)tblName configuration:(DWDatabaseConfiguration *)conf error:(NSError *__autoreleasing *)error {
    BOOL valid = [self validateConfiguration:conf considerTableName:NO error:error];
    if (!valid) {
        return NO;
    }
    return [self dw_createTableWithClass:cls tableName:tblName inQueue:conf.dbQueue error:error];
}

-(BOOL)createTableWithSQL:(NSString *)sql configuration:(DWDatabaseConfiguration *)conf error:(NSError * __autoreleasing *)error {
    
    BOOL valid = [self validateConfiguration:conf considerTableName:NO error:error];
    if (!valid) {
        return NO;
    }
    
    if (!sql.length) {
        NSError * err = errorWithMessage(@"Invalid sql whose length is 0.", 10007);
        safeLinkError(error, err);
        return NO;
    }
    
    __block BOOL success = NO;
    excuteOnDBOperationQueue(self, ^{
        [conf.dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
            ///建表
            success = [db executeUpdate:sql];
            safeLinkError(error, db.lastError);
        }];
    });
    return success;
}

-(DWDatabaseConfiguration *)fetchDBConfigurationWithName:(NSString *)name tabelName:(NSString *)tblName error:(NSError *__autoreleasing *)error {
    if (!tblName.length) {
        NSError * err = errorWithMessage(@"Invalid tblName whose length is 0.", 10005);
        safeLinkError(error, err);
        return nil;
    }
    
    DWDatabaseConfiguration * confTmp = [self fetchDBConfigurationWithName:name error:error];
    if (!confTmp) {
        return nil;
    }
    
    if (![self isTableExistWithTableName:tblName configuration:confTmp error:error]) {
        return nil;
    }
    return [[DWDatabaseConfiguration alloc] initWithName:name tblName:tblName dbq:confTmp.dbQueue];
}

-(BOOL)updateTableWithSQL:(NSString *)sql configuration:(DWDatabaseConfiguration *)conf error:(NSError *__autoreleasing *)error {
    
    BOOL valid = [self validateConfiguration:conf considerTableName:NO error:error];
    if (!valid) {
        return NO;
    }
    
    if (!sql.length) {
        NSError * err = errorWithMessage(@"Invalid sql whose length is 0.", 10007);
        safeLinkError(error, err);
        return NO;
    }
    
    __block BOOL success = NO;
    excuteOnDBOperationQueue(self, ^{
        [conf.dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
            success = [db executeUpdate:sql];
            safeLinkError(error, db.lastError);
        }];
    });
    return success;
}

-(BOOL)updateTableWithSQLs:(NSArray<NSString *> *)sqls rollbackOnFailure:(BOOL)rollback configuration:(DWDatabaseConfiguration *)conf error:(NSError *__autoreleasing *)error {
    
    BOOL valid = [self validateConfiguration:conf considerTableName:NO error:error];
    if (!valid) {
        return NO;
    }
    
    if (!sqls.count) {
        NSError * err = errorWithMessage(@"Invalid sqls whose count is 0.", 10007);
        safeLinkError(error, err);
        return NO;
    }
    
    __block BOOL success = NO;
    excuteOnDBOperationQueue(self, ^{
        [conf.dbQueue inTransaction:^(FMDatabase * _Nonnull db, BOOL * _Nonnull rollback) {
            [sqls enumerateObjectsUsingBlock:^(NSString * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                if (obj.length) {
                    success = [db executeUpdate:obj];
                    if (!success && rollback) {
                        *stop = YES;
                        *rollback = YES;
                    }
                    safeLinkError(error, db.lastError);
                }
            }];
        }];
    });
    return success;
}

-(FMResultSet *)queryTableWithSQL:(NSString *)sql configuration:(DWDatabaseConfiguration *)conf error:(NSError *__autoreleasing *)error {
    
    if (!sql.length) {
        NSError * err = errorWithMessage(@"Invalid sql whose length is 0.", 10007);
        safeLinkError(error, err);
        return nil;
    }
    
    BOOL valid = [self validateConfiguration:conf considerTableName:NO error:error];
    if (!valid) {
        return nil;
    }
    
    __block FMResultSet * ret = nil;
    excuteOnDBOperationQueue(self, ^{
        [conf.dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
            ret = [db executeQuery:sql];
            safeLinkError(error, db.lastError);
        }];
    });
    return ret;
}

-(NSArray<NSString *> *)queryAllFieldInTable:(BOOL)translateToPropertyName class:(Class)cls configuration:(DWDatabaseConfiguration *)conf error:(NSError *__autoreleasing  _Nullable *)error {
    BOOL valid = [self validateConfiguration:conf considerTableName:YES error:error];
    if (!valid) {
        return nil;
    }
    __block FMResultSet * set = nil;
    excuteOnDBOperationQueue(self, ^{
        [conf.dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
            set = [db getTableSchema:conf.tableName];
        }];
    });
    
    NSMutableArray * fields = [NSMutableArray arrayWithCapacity:0];
    while ([set next]) {
        [fields addObject:[set stringForColumn:@"name"]];
    }
    [set close];
    
    ///去除ID
    if ([fields containsObject:kUniqueID]) {
        [fields removeObject:kUniqueID];
    }
    if (!translateToPropertyName) {
        return fields;
    }
    if (translateToPropertyName && cls == Nil) {
        NSError * err = errorWithMessage(@"Invalid Class who is Nil.", 10017);
        safeLinkError(error, err);
        return nil;
    }
    NSDictionary <NSString *,DWPrefix_YYClassPropertyInfo *>* propInfos = [self propertyInfosForSaveKeysWithClass:cls];
    NSDictionary * map = databaseMapFromClass(cls);
    NSMutableArray * propNames = [NSMutableArray arrayWithCapacity:0];
    [propInfos enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, DWPrefix_YYClassPropertyInfo * _Nonnull obj, BOOL * _Nonnull stop) {
        if (obj.name.length) {
            NSString * field = propertyInfoTblName(obj, map);
            if (field.length && [fields containsObject:field]) {
                [propNames addObject:obj.name];
            }
        }
    }];
    
    ///如果个数不相等说明转换出现了问题
    if (propNames.count != fields.count) {
        NSError * err = errorWithMessage(@"Something wrong on translating fieldsName to propertyName.Checkout the result of propertyNames and find the reason.", 10020);
        safeLinkError(error, err);
    }
    return propNames;
}

-(BOOL)clearTableWithConfiguration:(DWDatabaseConfiguration *)conf error:(NSError *__autoreleasing *)error {
    
    BOOL valid = [self validateConfiguration:conf considerTableName:YES error:error];
    if (!valid) {
        return NO;
    }
    
    __block BOOL success = NO;
    excuteOnDBOperationQueue(self, ^{
        [conf.dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
            success = [db executeUpdate:[NSString stringWithFormat:@"DELETE FROM %@",conf.tableName]];
            safeLinkError(error, db.lastError);
        }];
    });
    
    return success;
}

-(BOOL)deleteTableWithConfiguration:(DWDatabaseConfiguration *)conf error:(NSError *__autoreleasing *)error {
    
    BOOL valid = [self validateConfiguration:conf considerTableName:YES error:error];
    if (!valid) {
        return NO;
    }
    
    __block BOOL success = NO;
    excuteOnDBOperationQueue(self, ^{
        [conf.dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
            success = [db executeUpdate:[NSString stringWithFormat:@"DROP TABLE IF EXISTS %@",conf.tableName]];
            safeLinkError(error, db.lastError);
        }];
    });
    return success;
}

-(BOOL)insertTableWithModel:(NSObject *)model keys:(NSArray<NSString *> *)keys configuration:(DWDatabaseConfiguration *)conf error:(NSError *__autoreleasing *)error {
    BOOL valid = [self validateConfiguration:conf considerTableName:YES error:error];
    if (!valid) {
        return NO;
    }
    [self supplyFieldIfNeededWithModel:model configuration:conf error:error];
    return [self dw_insertTableWithModel:model tableName:conf.tableName keys:keys inQueue:conf.dbQueue error:error];
}

-(NSArray<NSObject *> *)insertTableWithModels:(NSArray<NSObject *> *)models keys:(NSArray<NSString *> *)keys  rollbackOnFailure:(BOOL)rollback configuration:(DWDatabaseConfiguration *)conf error:(NSError *__autoreleasing  _Nullable *)error {
    
    NSMutableArray * failures = [NSMutableArray arrayWithCapacity:0];
    NSMutableArray * factorys = [NSMutableArray arrayWithCapacity:0];
    [models enumerateObjectsUsingBlock:^(NSObject * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        DWDatabaseSQLFactory * fac = [self insertSQLFactoryWithModel:obj tableName:conf.tableName keys:keys error:error];
        if (!fac) {
            [failures addObject:obj];
            ///如果失败就回滚的话，则此处无需再生成其他sql
            if (rollback) {
                *stop = YES;
            }
        } else {
            [factorys addObject:fac];
        }
    }];
    
    ///如果失败就回滚的话，此处无需再做插入操作，直接返回失败的模型
    if (rollback && failures.count > 0) {
        NSUInteger idx = [models indexOfObject:failures.lastObject];
        return [models subarrayWithRange:NSMakeRange(idx, models.count - idx)];
    }
    
    __block BOOL hasFailure = NO;
    ///使用一个临时的Error，防止由于原生error已经被释放后野指针调用崩溃问题
    __block NSError * errorRetain;
    excuteOnDBOperationQueue(self, ^{
        [conf.dbQueue inTransaction:^(FMDatabase * _Nonnull db, BOOL * _Nonnull rollbackP) {
            [factorys enumerateObjectsUsingBlock:^(DWDatabaseSQLFactory * obj, NSUInteger idx, BOOL * _Nonnull stop) {
                ///如果还没失败过则执行插入操作
                if (!hasFailure) {
                    ///如果插入失败则记录失败状态并将模型加入失败数组
                    [self supplyFieldIfNeededWithModel:obj.model configuration:conf error:error];
                    if (![self insertIntoDBWithDatabase:db factory:obj error:&errorRetain]) {
                        hasFailure = YES;
                        [failures addObject:obj.model];
                    }
                } else {
                    ///如果失败过，直接将模型加入数组即可
                    [failures addObject:obj.model];
                }
            }];
            
            ///如果失败了，按需回滚
            if (hasFailure) {
                *rollbackP = rollback;
            }
        }];
    });
    
    safeLinkError(error, errorRetain);
    return failures.count?failures:nil;
}

-(void)insertTableWithModels:(NSArray<NSObject *> *)models keys:(NSArray<NSString *> *)keys rollbackOnFailure:(BOOL)rollback configuration:(DWDatabaseConfiguration *)conf completion:(void (^)(NSArray<NSObject *> * _Nonnull, NSError * _Nonnull))completion {
    asyncExcuteOnDBOperationQueue(self, ^{
        NSError * error;
        NSMutableArray * ret = (NSMutableArray *)[self insertTableWithModels:models keys:keys rollbackOnFailure:rollback configuration:conf error:&error];
        if (completion) {
            completion(ret,error);
        }
    });
}

-(BOOL)deleteTableWithModel:(NSObject *)model byDw_id:(BOOL)byID keys:(NSArray <NSString *>*)keys configuration:(DWDatabaseConfiguration *)conf error:(NSError *__autoreleasing *)error {
    BOOL valid = [self validateConfiguration:conf considerTableName:YES error:error];
    if (!valid) {
        return NO;
    }
    return [self dw_deleteTableWithModel:model tableName:conf.tableName byDw_id:byID keys:keys inQueue:conf.dbQueue error:error];
}

-(BOOL)updateTableWithModel:(NSObject *)model keys:(NSArray <NSString *>*)keys configuration:(DWDatabaseConfiguration *)conf error:(NSError *__autoreleasing *)error {
    BOOL valid = [self validateConfiguration:conf considerTableName:YES error:error];
    if (!valid) {
        return NO;
    }
    [self supplyFieldIfNeededWithModel:model configuration:conf error:error];
    return [self dw_updateTableWithModel:model tableName:conf.tableName keys:keys inQueue:conf.dbQueue error:error];
}

-(NSArray <NSObject *>*)queryTableWithClass:(Class)clazz keys:(NSArray <NSString *>*)keys limit:(NSUInteger)limit offset:(NSUInteger)offset orderKey:(NSString *)orderKey ascending:(BOOL)ascending configuration:(DWDatabaseConfiguration *)conf error:(NSError * _Nullable __autoreleasing *)error condition:(void(^)(DWDatabaseConditionMaker * maker))condition {
    
    if (!clazz && !condition) {
        NSError * err = errorWithMessage(@"Invalid query without any condition.", 10010);
        safeLinkError(error, err);
        return nil;
    }
    
    BOOL valid = [self validateConfiguration:conf considerTableName:YES error:error];
    if (!valid) {
        return nil;
    }
    
    if (!condition) {
        condition = ^(DWDatabaseConditionMaker * maker) {
            maker.loadClass(clazz);
        };
    }
    
    return [self dw_queryTableWithTableName:conf.tableName keys:keys limit:limit offset:offset orderKey:orderKey ascending:ascending inQueue:conf.dbQueue error:error condition:condition];
}

-(void)queryTableWithClass:(Class)clazz keys:(NSArray <NSString *>*)keys limit:(NSUInteger)limit offset:(NSUInteger)offset orderKey:(NSString *)orderKey ascending:(BOOL)ascending configuration:(DWDatabaseConfiguration *)conf condition:(void(^)(DWDatabaseConditionMaker * maker))condition completion:(void (^)(NSArray<__kindof NSObject *> *, NSError *))completion {
    asyncExcuteOnDBOperationQueue(self, ^{
        NSError * error;
        NSMutableArray * ret = (NSMutableArray *)[self queryTableWithClass:clazz keys:keys limit:limit offset:offset orderKey:orderKey ascending:ascending configuration:conf error:&error condition:condition];
        if (completion) {
            completion(ret,error);
        }
    });
}

-(NSArray<NSObject *> *)queryTableWithSQL:(NSString *)sql class:(Class)cls configuration:(DWDatabaseConfiguration *)conf error:(NSError *__autoreleasing  _Nullable *)error {
    if (!sql.length) {
        NSError * err = errorWithMessage(@"Invalid sql whose length is 0.", 10007);
        safeLinkError(error, err);
        return nil;
    }
    
    if (cls == Nil) {
        NSError * err = errorWithMessage(@"Invalid Class who is Nil.", 10017);
        safeLinkError(error, err);
        return nil;
    }
    
    BOOL valid = [self validateConfiguration:conf considerTableName:YES error:error];
    if (!valid) {
        return nil;
    }
    
    FMResultSet * set = [self queryTableWithSQL:sql configuration:conf error:error];
    NSDictionary <NSString *,DWPrefix_YYClassPropertyInfo *>* props = [self propertyInfosForSaveKeysWithClass:cls];
    NSDictionary * map = databaseMapFromClass(cls);
    NSMutableArray * ret = [NSMutableArray arrayWithCapacity:0];
    while ([set next]) {
        id tmp = [cls new];
        if (!tmp) {
            NSError * err = errorWithMessage(@"Invalid Class who is Nil.", 10017);
            safeLinkError(error, err);
            return nil;
        }
        __block BOOL validValue = NO;
        [props enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, DWPrefix_YYClassPropertyInfo * _Nonnull obj, BOOL * _Nonnull stop) {
            if (obj.name.length) {
                NSString * name = propertyInfoTblName(obj, map);
                if (name.length) {
                    id value = [set objectForColumn:name];
                    modelSetValueWithPropertyInfo(tmp, obj, value);
                    validValue = YES;
                }
            }
        }];
        if (validValue) {
            NSNumber * Dw_id = [set objectForColumn:kUniqueID];
            if (Dw_id) {
                SetDw_idForModel(tmp, Dw_id);
            }
            [ret addObject:tmp];
        }
    }
    return ret;
}

-(void)queryTableWithSQL:(NSString *)sql class:(Class)cls configuration:(DWDatabaseConfiguration *)conf completion:(void (^)(NSArray<__kindof NSObject *> * _Nonnull, NSError * _Nonnull))completion {
    asyncExcuteOnDBOperationQueue(self, ^{
        NSError * error;
        NSMutableArray * ret = (NSMutableArray *)[self queryTableWithSQL:sql class:cls configuration:conf error:&error];
        if (completion) {
            completion(ret,error);
        }
    });
}

-(NSArray<NSObject *> *)queryTableWithClass:(Class)clazz keys:(NSArray *)keys configuration:(DWDatabaseConfiguration *)conf error:(NSError *__autoreleasing *)error condition:(void (^)(DWDatabaseConditionMaker * ))condition {
    
    if (!clazz && !condition) {
        NSError * err = errorWithMessage(@"Invalid query without any condition.", 10010);
        safeLinkError(error, err);
        return nil;
    }
    
    BOOL valid = [self validateConfiguration:conf considerTableName:YES error:error];
    if (!valid) {
        return nil;
    }
    
    if (!condition) {
        condition = ^(DWDatabaseConditionMaker * maker) {
            maker.loadClass(clazz);
        };
    }
    return [self dw_queryTableWithTableName:conf.tableName keys:keys limit:0 offset:0 orderKey:nil ascending:YES inQueue:conf.dbQueue error:error condition:condition];
}

-(NSInteger)queryTableForCountWithClass:(Class)clazz configuration:(DWDatabaseConfiguration *)conf error:(NSError * _Nullable __autoreleasing *)error condition:(void (^)(DWDatabaseConditionMaker * _Nonnull))condition {
    
    if (!clazz && !condition) {
        NSError * err = errorWithMessage(@"Invalid query without any condition.", 10010);
        safeLinkError(error, err);
        return -1;
    }
    
    BOOL valid = [self validateConfiguration:conf considerTableName:YES error:error];
    if (!valid) {
        return -1;
    }
    
    if (!condition) {
        condition = ^(DWDatabaseConditionMaker * maker) {
            maker.loadClass(clazz);
        };
    }
    
    return [self dw_queryTableForCountWithTableName:conf.tableName inQueue:conf.dbQueue error:error condition:condition];
}

-(NSObject *)queryTableWithClass:(Class)cls Dw_id:(NSNumber *)Dw_id keys:(NSArray<NSString *> *)keys configuration:(DWDatabaseConfiguration *)conf error:(NSError *__autoreleasing  _Nullable *)error {
    if (!Dw_id) {
        NSError * err = errorWithMessage(@"Invalid Dw_id who is Nil.", 10018);
        safeLinkError(error, err);
        return nil;
    }
    BOOL valid = [self validateConfiguration:conf considerTableName:YES error:error];
    if (!valid) {
        return nil;
    }
    
    return [self dw_queryTableWithModel:[cls new] tableName:conf.tableName conditionMap:@{kUniqueID:Dw_id} keys:keys limit:0 offset:0 orderKey:nil ascending:YES inQueue:conf.dbQueue error:error condition:nil resultSetHandler:^(__unsafe_unretained Class cls, FMResultSet *set, NSDictionary<NSString *,DWPrefix_YYClassPropertyInfo *> *validProInfos, NSDictionary *databaseMap, NSMutableArray *resultArr, BOOL *stop, BOOL *returnNil, NSError *__autoreleasing *error) {
        id tmp = [cls new];
        if (!tmp) {
            NSError * err = errorWithMessage(@"Invalid Class who is Nil.", 10017);
            safeLinkError(error, err);
            *stop = YES;
            *returnNil = YES;
            return;
        }
        __block BOOL validValue = NO;
        [validProInfos enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, DWPrefix_YYClassPropertyInfo * _Nonnull obj, BOOL * _Nonnull stop) {
            if (obj.name.length) {
                NSString * name = propertyInfoTblName(obj, databaseMap);
                if (name.length) {
                    id value = [set objectForColumn:name];
                    modelSetValueWithPropertyInfo(tmp, obj, value);
                    validValue = YES;
                }
            }
        }];
        if (validValue) {
            NSNumber * Dw_id = [set objectForColumn:kUniqueID];
            if (Dw_id) {
                SetDw_idForModel(tmp, Dw_id);
            }
            [resultArr addObject:tmp];
            *stop = YES;
        }
    }].lastObject;
}

-(NSNumber *)fetchDw_idForModel:(NSObject *)model {
    if (!model) {
        return nil;
    }
    return Dw_idFromModel(model);
}

#pragma mark --- tool method ---
#pragma mark ------ 建表 ------
-(BOOL)dw_createTableWithClass:(Class)cls tableName:(NSString *)tblName inQueue:(FMDatabaseQueue *)queue error:(NSError * __autoreleasing *)error {
    if (cls == Nil) {
        NSError * err = errorWithMessage(@"Invalid Class who is Nil.", 10017);
        safeLinkError(error, err);
        return NO;
    }
    if (!queue) {
        NSError * err = errorWithMessage(@"Invalid FMDatabaseQueue who is nil.", 10015);
        safeLinkError(error, err);
        return NO;
    }
    if (!tblName.length) {
        tblName = [NSStringFromClass(cls) stringByAppendingString:@"_tbl"];
    }
    
    DWDatabaseSQLFactory * fac = [self createSQLFactoryWithClass:cls tableName:tblName error:error];
    if (!fac) {
        return NO;
    }
    
    __block BOOL success = NO;
    excuteOnDBOperationQueue(self, ^{
        [queue inDatabase:^(FMDatabase * _Nonnull db) {
            ///建表
            success = [db executeUpdate:fac.sql];
            safeLinkError(error, db.lastError);
        }];
    });
    
    return success;
}

#pragma mark ------ 插入表 ------
-(BOOL)dw_insertTableWithModel:(NSObject *)model tableName:(NSString *)tblName keys:(NSArray <NSString *>*)keys inQueue:(FMDatabaseQueue *)queue error:(NSError * __autoreleasing *)error {
    if (!queue) {
        NSError * err = errorWithMessage(@"Invalid FMDatabaseQueue who is nil.", 10015);
        safeLinkError(error, err);
        return NO;
    }
    
    DWDatabaseSQLFactory * factory = [self insertSQLFactoryWithModel:model tableName:tblName keys:keys error:error];
    if (!factory) {
        return NO;
    }
    
    ///至此已取到合法sql
    __block BOOL success = NO;
    excuteOnDBOperationQueue(self, ^{
        [queue inDatabase:^(FMDatabase * _Nonnull db) {
            success = [self insertIntoDBWithDatabase:db factory:factory error:error];
        }];
    });
    
    return success;
}

#pragma mark ------ 表删除 ------
-(BOOL)dw_deleteTableWithModel:(NSObject *)model tableName:(NSString *)tblName byDw_id:(BOOL)byID keys:(NSArray <NSString *>*)keys inQueue:(FMDatabaseQueue *)queue error:(NSError *__autoreleasing *)error {
    if (!queue) {
        NSError * err = errorWithMessage(@"Invalid FMDatabaseQueue who is nil.", 10015);
        safeLinkError(error, err);
        return NO;
    }
    if (!tblName.length) {
        NSError * err = errorWithMessage(@"Invalid tblName whose length is 0.", 10005);
        safeLinkError(error, err);
        return NO;
    }
    if (!model) {
        NSError * err = errorWithMessage(@"Invalid model who is nil.", 10016);
        safeLinkError(error, err);
        return NO;
    }
    NSNumber * Dw_id = Dw_idFromModel(model);
    __block BOOL success = NO;
    ///ID存在删除对应ID，不存在删除所有值相等的条目
    if (Dw_id && byID) {
        NSString * sql = [NSString stringWithFormat:@"DELETE FROM %@ WHERE %@ = ?",tblName,kUniqueID];
        excuteOnDBOperationQueue(self, ^{
            [queue inDatabase:^(FMDatabase * _Nonnull db) {
                success = [db executeUpdate:sql withArgumentsInArray:@[Dw_id]];
                safeLinkError(error, db.lastError);
            }];
        });
    } else {
        DWDatabaseSQLFactory * fac = [self deleteSQLFactoryWithModel:model tableName:tblName keys:keys error:error];
        if (!fac) {
            return NO;
        }
        excuteOnDBOperationQueue(self, ^{
            [queue inDatabase:^(FMDatabase * _Nonnull db) {
                success = [db executeUpdate:fac.sql withArgumentsInArray:fac.args];
                safeLinkError(error, db.lastError);
            }];
        });
    }
    
    ///删除后移除Dw_id
    SetDw_idForModel(model, nil);
    return success;
}

#pragma mark ------ 更新表 ------
-(BOOL)dw_updateTableWithModel:(NSObject *)model tableName:(NSString *)tblName keys:(NSArray <NSString *>*)keys inQueue:(FMDatabaseQueue *)queue error:(NSError * __autoreleasing *)error {
    if (!queue) {
        NSError * err = errorWithMessage(@"Invalid FMDatabaseQueue who is nil.", 10015);
        safeLinkError(error, err);
        return NO;
    }
    if (!tblName.length) {
        NSError * err = errorWithMessage(@"Invalid tblName whose length is 0.", 10005);
        safeLinkError(error, err);
        return NO;
    }
    if (!model) {
        NSError * err = errorWithMessage(@"Invalid model who is nil.", 10016);
        safeLinkError(error, err);
        return NO;
    }
    
    NSNumber * Dw_id = Dw_idFromModel(model);
    __block BOOL success = NO;
    if (Dw_id) {
        DWDatabaseSQLFactory * fac = [self updateSQLFactoryWithModel:model Dw_id:Dw_id tableName:tblName keys:keys error:error];
        if (!fac) {
            return NO;
        }
        excuteOnDBOperationQueue(self, ^{
            [queue inDatabase:^(FMDatabase * _Nonnull db) {
                success = [db executeUpdate:fac.sql withArgumentsInArray:fac.args];
                safeLinkError(error, db.lastError);
            }];
        });
    } else {
        ///不存在ID则不做更新操作，做插入操作
        ///插入操作后最好把Dw_id赋值
        success = [self dw_insertTableWithModel:model tableName:tblName keys:keys inQueue:queue error:error];
    }
    return success;
}

#pragma mark ------ 查询表 ------

-(NSArray <__kindof NSObject *>*)dw_queryTableWithModel:(NSObject *)model tableName:(NSString *)tblName conditionMap:(NSDictionary *)conditionMap keys:(NSArray *)keys limit:(NSUInteger)limit offset:(NSUInteger)offset orderKey:(NSString *)orderKey ascending:(BOOL)ascending inQueue:(FMDatabaseQueue *)queue error:(NSError *__autoreleasing *)error condition:(void(^)(DWDatabaseConditionMaker * maker))condition resultSetHandler:(void(^)(Class cls,FMResultSet * set,NSDictionary <NSString *,DWPrefix_YYClassPropertyInfo *>*validProInfos,NSDictionary * databaseMap,NSMutableArray * resultArr,BOOL * stop,BOOL * returnNil,NSError * __autoreleasing * error))handler {
    if (!queue) {
        NSError * err = errorWithMessage(@"Invalid FMDatabaseQueue who is nil.", 10015);
        safeLinkError(error, err);
        return nil;
    }
    if (!tblName.length) {
        NSError * err = errorWithMessage(@"Invalid tblName whose length is 0.", 10005);
        safeLinkError(error, err);
        return nil;
    }
    if (!model && !condition) {
        NSError * err = errorWithMessage(@"Invalid query without any condition.", 10010);
        safeLinkError(error, err);
        return nil;
    }
    
    ///获取条件字段组并获取本次的class
    NSMutableArray * args = @[].mutableCopy;
    NSMutableArray * conditionStrings = @[].mutableCopy;
    NSMutableArray * validConditionKeys = @[].mutableCopy;
    Class cls;
    NSArray * saveKeys = nil;
    NSDictionary * map = nil;
    if (condition) {
        DWDatabaseConditionMaker * maker = [DWDatabaseConditionMaker new];
        condition(maker);
        cls = [maker fetchQueryClass];
        if (!cls) {
            cls = [model class];
        }
        saveKeys = [self propertysToSaveWithClass:cls];
        map = databaseMapFromClass(cls);
        NSDictionary * propertyInfos = [self propertyInfosWithClass:cls keys:saveKeys];
        [maker configWithPropertyInfos:propertyInfos databaseMap:map];
        [maker make];
        [args addObjectsFromArray:[maker fetchArguments]];
        [conditionStrings addObjectsFromArray:[maker fetchConditions]];
        [validConditionKeys addObjectsFromArray:[maker fetchValidKeys]];
    } else {
        cls = [model class];
        saveKeys = [self propertysToSaveWithClass:cls];
        map = databaseMapFromClass(cls);
        if (conditionMap.allKeys.count) {
            [conditionMap enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
                [args addObject:obj];
                [conditionStrings addObject:[key stringByAppendingString:@" = ?"]];
                [validConditionKeys addObject:[key stringByAppendingString:@"0"]];
            }];
        }
    }
    
    if (!saveKeys.count) {
        NSString * msg = [NSString stringWithFormat:@"Invalid Class(%@) who have no valid key.",NSStringFromClass(cls)];
        NSError * err = errorWithMessage(msg, 10013);
        safeLinkError(error, err);
        return nil;
    }

    BOOL queryAll = NO;
    ///如果keys为空则试图查询cls与表对应的所有键值
    if (!keys.count) {
        keys = [self propertysToSaveWithClass:cls];
        ///如果所有键值为空则返回空
        if (!keys.count) {
            NSError * err = errorWithMessage(@"Invalid query keys which has no key in save keys.", 10008);
            safeLinkError(error, err);
            return nil;
        }
        queryAll = YES;
    } else {
        ///如果不为空，则将keys与对应键值做交集
        keys = intersectionOfArray(keys, saveKeys);
        if (!keys.count) {
            NSError * err = errorWithMessage(@"Invalid query keys which has no key in save keys.", 10008);
            safeLinkError(error, err);
            return nil;
        }
    }

    NSMutableArray * validQueryKeys = [NSMutableArray arrayWithCapacity:0];
    NSDictionary <NSString *,DWPrefix_YYClassPropertyInfo *>*queryKeysProInfos = [self propertyInfosWithClass:cls keys:keys];

    if (!queryKeysProInfos.allKeys.count) {
        NSString * msg = [NSString stringWithFormat:@"Invalid Class(%@) who have no valid key to query.",NSStringFromClass(cls)];
        NSError * err = errorWithMessage(msg, 10009);
        safeLinkError(error, err);
        return nil;
    }

    ///获取查询字符串数组
    if (queryAll) {
        [validQueryKeys addObject:@"*"];
    } else {
        [validQueryKeys addObject:kUniqueID];
        [self configInfos:queryKeysProInfos map:map model:nil validKeysContainer:validQueryKeys argumentsContaienr:nil appendingString:nil];
        if (validQueryKeys.count == 1) {
            NSString * msg = [NSString stringWithFormat:@"Invalid Class(%@) who have no valid keys to query.",NSStringFromClass(cls)];
            NSError * err = errorWithMessage(msg, 10009);
            safeLinkError(error, err);
            return nil;
        }
    }

    ///如果无查询参数置为nil方便后面直接传参
    if (!args.count) {
        args = nil;
    }
    
    ///获取所有关键字段组
    NSMutableArray * validKeys = [NSMutableArray arrayWithArray:validQueryKeys];
    [validKeys addObjectsFromArray:validConditionKeys];

    NSString * sql = nil;
    ///先尝试取缓存的sql
    NSString * cacheSqlKey = [self sqlCacheKeyWithPrefix:kQueryPrefix class:cls tblName:tblName keys:validKeys];

    ///有排序添加排序
    NSString * orderField = nil;
    if (orderKey.length && [saveKeys containsObject:orderKey]) {
        DWPrefix_YYClassPropertyInfo * prop = [[self propertyInfosWithClass:cls keys:@[orderKey]] valueForKey:orderKey];
        if (prop) {
            NSString * field = propertyInfoTblName(prop, map);
            if (field.length) {
                orderField = field;

            }
        }
    }

    ///如果排序键不合法，则以Dw_id为排序键
    if (!orderField.length) {
        orderField = kUniqueID;
    }
    cacheSqlKey = [cacheSqlKey stringByAppendingString:[NSString stringWithFormat:@"-%@-%@",orderField,ascending?@"ASC":@"DESC"]];

    if (limit > 0) {
        cacheSqlKey = [cacheSqlKey stringByAppendingString:[NSString stringWithFormat:@"-L%lu",(unsigned long)limit]];
    }
    if (offset > 0) {
        cacheSqlKey = [cacheSqlKey stringByAppendingString:[NSString stringWithFormat:@"-O%lu",(unsigned long)offset]];
    }
    if (cacheSqlKey.length) {
        sql = [self.sqlsCache valueForKey:cacheSqlKey];
    }
    ///如果没有缓存的sql则拼装sql
    if (!sql) {
        
        ///条件查询模式，所有值均为查询值，故将条件值加至查询数组
        NSMutableArray * actualQueryKeys = [NSMutableArray arrayWithArray:validQueryKeys];
        if (!queryAll) {
            [actualQueryKeys addObjectsFromArray:validConditionKeys];
        }
        
        ///先配置更新值得sql
        sql = [NSString stringWithFormat:@"SELECT %@ FROM %@",[actualQueryKeys componentsJoinedByString:@","],tblName];

        ///如果有有效条件时拼装条件值，若无有效条件时且有有效条件字典时拼装有效条件字符串
        if (args.count) {
            sql = [sql stringByAppendingString:[NSString stringWithFormat:@" WHERE %@",[conditionStrings componentsJoinedByString:@" AND "]]];
        }

        ///有排序添加排序
        if (orderField.length) {
            sql = [sql stringByAppendingString:[NSString stringWithFormat:@" ORDER BY %@ %@",orderField,ascending?@"ASC":@"DESC"]];
        }
        if (limit > 0) {
            sql = [sql stringByAppendingString:[NSString stringWithFormat:@" LIMIT %lu",(unsigned long)limit]];
        }
        if (offset > 0) {
            sql = [sql stringByAppendingString:[NSString stringWithFormat:@" OFFSET %lu",(unsigned long)offset]];
        }

        ///计算完缓存sql
        if (cacheSqlKey.length) {
            [self.sqlsCache setValue:sql forKey:cacheSqlKey];
        }
    }

    ///得到结果
    __block FMResultSet * set = nil;
    excuteOnDBOperationQueue(self, ^{
        [queue inDatabase:^(FMDatabase * _Nonnull db) {
            set = [db executeQuery:sql withArgumentsInArray:args];
            safeLinkError(error, db.lastError);
        }];
    });

    ///获取带转换的属性
    NSDictionary * validPropertyInfo = nil;
    if (queryAll) {
        validPropertyInfo = [self propertyInfosWithClass:cls keys:saveKeys];
    } else {
        validPropertyInfo = [self propertyInfosWithClass:cls keys:validKeys];
    }
    
    ///组装数组
    NSMutableArray * ret = [NSMutableArray arrayWithCapacity:0];
    BOOL stop = NO;
    BOOL returnNil = NO;
    while ([set next]) {
        if (handler) {
            handler(cls,set,validPropertyInfo,map,ret,&stop,&returnNil,error);
        }
        if (stop) {
            break;
        }
    }
    [set close];

    if (returnNil) {
        return nil;
    }

    if (!ret.count) {
        NSError * err = errorWithMessage(@"There's no result with this conditions", 10011);
        safeLinkError(error, err);
    }
    return ret;
}

#pragma mark ------ 其他 ------
-(DWDatabaseSQLFactory *)createSQLFactoryWithClass:(Class)cls tableName:(NSString *)tblName  error:(NSError *__autoreleasing *)error {
    NSDictionary * props = [self propertyInfosForSaveKeysWithClass:cls];
    if (!props.allKeys.count) {
        NSString * msg = [NSString stringWithFormat:@"Invalid Class(%@) who have no save key.",NSStringFromClass(cls)];
        NSError * err = errorWithMessage(msg, 10012);
        safeLinkError(error, err);
        return nil;
    }
    
    NSString * sql = nil;
    ///先尝试取缓存的sql
    NSString * cacheSqlKey = [self sqlCacheKeyWithPrefix:kCreatePrefix class:cls tblName:tblName keys:@[@"CREATE-SQL"]];
    if (cacheSqlKey.length) {
        sql = [self.sqlsCache valueForKey:cacheSqlKey];
    }
    ///如果没有缓存的sql则拼装sql
    if (!sql) {
        ///添加模型表键值转化
        NSDictionary * map = databaseMapFromClass(cls);
        NSMutableArray * validKeys = [NSMutableArray arrayWithCapacity:0];
        [props enumerateKeysAndObjectsUsingBlock:^(NSString * key, DWPrefix_YYClassPropertyInfo * obj, BOOL * _Nonnull stop) {
            ///转化完成的键名及数据类型
            NSString * field = tblFieldStringFromPropertyInfo(obj,map);
            if (field.length) {
                [validKeys addObject:field];
            }
        }];
        
        if (!validKeys.count) {
            NSString * msg = [NSString stringWithFormat:@"Invalid Class(%@) who have no valid keys to create table.",NSStringFromClass(cls)];
            NSError * err = errorWithMessage(msg, 10009);
            safeLinkError(error, err);
            return nil;
        }
        
        ///对表中字段名进行排序
        [validKeys sortUsingSelector:@selector(compare:)];
        
        ///拼装sql语句
        sql = [NSString stringWithFormat:@"CREATE TABLE IF NOT EXISTS %@ (%@ INTEGER PRIMARY KEY AUTOINCREMENT,%@)",tblName,kUniqueID,[validKeys componentsJoinedByString:@","]];
        ///计算完缓存sql
        if (cacheSqlKey.length) {
            [self.sqlsCache setValue:sql forKey:cacheSqlKey];
        }
    }
    DWDatabaseSQLFactory * fac = [DWDatabaseSQLFactory new];
    fac.sql = sql;
    return fac;
}

-(DWDatabaseSQLFactory *)insertSQLFactoryWithModel:(NSObject *)model tableName:(NSString *)tblName keys:(NSArray<NSString *> *)keys error:(NSError *__autoreleasing *)error {
    Class cls = [model class];
    if (!tblName.length) {
        NSError * err = errorWithMessage(@"Invalid tblName whose length is 0.", 10005);
        safeLinkError(error, err);
        return nil;
    }
    if (!model) {
        NSError * err = errorWithMessage(@"Invalid model who is nil.", 10016);
        safeLinkError(error, err);
        return nil;
    }
    NSDictionary * infos = nil;
    if (keys.count) {
        infos = [self propertyInfosWithClass:cls keys:keys];
    } else {
        infos = [self propertyInfosForSaveKeysWithClass:cls];
    }
    if (!infos.allKeys.count) {
        NSString * msg = [NSString stringWithFormat:@"Invalid model(%@) who have no valid key.",model];
        NSError * err = errorWithMessage(msg, 10013);
        safeLinkError(error, err);
        return nil;
    }
    
    ///先看有效插入值，根据有效插入值确定sql
    NSMutableArray * args = [NSMutableArray arrayWithCapacity:0];
    NSMutableArray * validKeys = [NSMutableArray arrayWithCapacity:0];
    NSDictionary * map = databaseMapFromClass(cls);
    
    [self configInfos:infos map:map model:model validKeysContainer:validKeys argumentsContaienr:args appendingString:nil];
    
    ///无有效插入值
    if (!args.count) {
        NSString * msg = [NSString stringWithFormat:@"Invalid model(%@) who have no valid value to insert.",model];
        NSError * err = errorWithMessage(msg, 10009);
        safeLinkError(error, err);
        return nil;
    }
    
    NSString * sql = nil;
    ///先尝试取缓存的sql
    NSString * cacheSqlKey = [self sqlCacheKeyWithPrefix:kInsertPrefix class:cls tblName:tblName keys:validKeys];
    if (cacheSqlKey.length) {
        sql = [self.sqlsCache valueForKey:cacheSqlKey];
    }
    ///如果没有缓存的sql则拼装sql
    if (!sql) {
        ///先配置更新值得sql
        sql = [NSString stringWithFormat:@"INSERT INTO %@ (%@) VALUES (",tblName,[validKeys componentsJoinedByString:@","]];
        ///再配置值
        NSString * doubt = @"";
        for (int i = 0,max = (int)args.count; i < max; i++) {
            doubt = [doubt stringByAppendingString:@"?,"];
        }
        doubt = [doubt substringToIndex:doubt.length - 1];
        sql = [sql stringByAppendingString:[NSString stringWithFormat:@"%@)",doubt]];
        ///计算完缓存sql
        if (cacheSqlKey.length) {
            [self.sqlsCache setValue:sql forKey:cacheSqlKey];
        }
    }
    DWDatabaseSQLFactory * fac = [DWDatabaseSQLFactory new];
    fac.sql = sql;
    fac.args = args;
    fac.model = model;
    return fac;
}

-(DWDatabaseSQLFactory *)deleteSQLFactoryWithModel:(NSObject *)model tableName:(NSString *)tblName keys:(NSArray<NSString *> *)keys error:(NSError *__autoreleasing *)error {
    NSDictionary * infos = nil;
    Class cls = [model class];
    if (keys.count) {
        infos = [self propertyInfosWithClass:cls keys:keys];
    } else {
        infos = [self propertyInfosForSaveKeysWithClass:cls];
    }
    
    if (!infos.allKeys.count) {
        NSString * msg = [NSString stringWithFormat:@"Invalid model(%@) who have no valid key.",model];
        NSError * err = errorWithMessage(msg, 10013);
        safeLinkError(error, err);
        return nil;
    }
    ///存在ID可以做更新操作
    NSMutableArray * args = [NSMutableArray arrayWithCapacity:0];
    NSMutableArray * validKeys = [NSMutableArray arrayWithCapacity:0];
    NSDictionary * map = databaseMapFromClass(cls);
    ///先配置更新值得sql
    [self configInfos:infos map:map model:model validKeysContainer:validKeys argumentsContaienr:args appendingString:@" = ?"];
    
    ///无有效插入值
    if (!args.count) {
        NSString * msg = [NSString stringWithFormat:@"Invalid model(%@) who have no valid value to delete.",model];
        NSError * err = errorWithMessage(msg, 10009);
        safeLinkError(error, err);
        return nil;
    }
    
    NSString * sql = nil;
    ///先尝试取缓存的sql
    NSString * cacheSqlKey = [self sqlCacheKeyWithPrefix:kDeletePrefix class:cls tblName:tblName keys:validKeys];
    if (cacheSqlKey.length) {
        sql = [self.sqlsCache valueForKey:cacheSqlKey];
    }
    ///如果没有缓存的sql则拼装sql
    if (!sql) {
        ///先配置更新值得sql
        sql = [NSString stringWithFormat:@"DELETE FROM %@ WHERE %@",tblName,[validKeys componentsJoinedByString:@" AND "]];
        ///计算完缓存sql
        if (cacheSqlKey.length) {
            [self.sqlsCache setValue:sql forKey:cacheSqlKey];
        }
    }
    DWDatabaseSQLFactory * fac = [DWDatabaseSQLFactory new];
    fac.sql = sql;
    fac.args = args;
    fac.model = model;
    return fac;
}

-(DWDatabaseSQLFactory *)updateSQLFactoryWithModel:(NSObject *)model Dw_id:(NSNumber *)Dw_id tableName:(NSString *)tblName keys:(NSArray<NSString *> *)keys error:(NSError *__autoreleasing *)error {
    NSDictionary * infos = nil;
    Class cls = [model class];
    ///如果指定更新key则取更新key的infos信息
    if (keys.count) {
        infos = [self propertyInfosWithClass:cls keys:keys];
    } else {
        infos = [self propertyInfosForSaveKeysWithClass:cls];
    }
    if (!infos.allKeys.count) {
        NSString * msg = [NSString stringWithFormat:@"Invalid model(%@) who have no valid key.",model];
        NSError * err = errorWithMessage(msg, 10013);
        safeLinkError(error, err);
        return nil;
    }
    ///存在ID可以做更新操作
    NSMutableArray * args = [NSMutableArray arrayWithCapacity:0];
    NSMutableArray * validKeys = [NSMutableArray arrayWithCapacity:0];
    NSDictionary * map = databaseMapFromClass(cls);
    
    ///先配置更新值得sql
    [self configInfos:infos map:map model:model validKeysContainer:validKeys argumentsContaienr:args appendingString:@" = ?"];
    
    ///无有效插入值
    if (!args.count) {
        NSString * msg = [NSString stringWithFormat:@"Invalid model(%@) who have no valid value to update.",model];
        NSError * err = errorWithMessage(msg, 10009);
        safeLinkError(error, err);
        return nil;
    }
    
    NSString * sql = nil;
    ///先尝试取缓存的sql
    NSString * cacheSqlKey = [self sqlCacheKeyWithPrefix:kUpdatePrefix class:cls tblName:tblName keys:validKeys];
    if (cacheSqlKey.length) {
        sql = [self.sqlsCache valueForKey:cacheSqlKey];
    }
    ///如果没有缓存的sql则拼装sql
    if (!sql) {
        ///先配置更新值得sql
        sql = [NSString stringWithFormat:@"UPDATE %@ SET %@",tblName,[validKeys componentsJoinedByString:@","]];
        ///计算完缓存sql
        if (cacheSqlKey.length) {
            [self.sqlsCache setValue:sql forKey:cacheSqlKey];
        }
    }
    
    ///后配置Dw_id的sql
    sql = [sql stringByAppendingString:[NSString stringWithFormat:@" WHERE %@ = ?",kUniqueID]];
    [args addObject:Dw_id];
    DWDatabaseSQLFactory * fac = [DWDatabaseSQLFactory new];
    fac.sql = sql;
    fac.args = args;
    fac.model = model;
    return fac;
}

-(BOOL)insertIntoDBWithDatabase:(FMDatabase *)db factory:(DWDatabaseSQLFactory *)fac error:(NSError *__autoreleasing *)error {
    BOOL success = [db executeUpdate:fac.sql withArgumentsInArray:fac.args];
    if (success) {
        SetDw_idForModel(fac.model, @(db.lastInsertRowId));
    }
    safeLinkError(error, db.lastError);
    return success;
}


-(NSArray <__kindof NSObject *>*)dw_queryTableWithTableName:(NSString *)tblName keys:(NSArray *)keys limit:(NSUInteger)limit offset:(NSUInteger)offset orderKey:(NSString *)orderKey ascending:(BOOL)ascending inQueue:(FMDatabaseQueue *)queue error:(NSError *__autoreleasing *)error condition:(void(^)(DWDatabaseConditionMaker * maker))condition {

    return [self dw_queryTableWithModel:nil tableName:tblName conditionMap:nil keys:keys limit:limit offset:offset orderKey:orderKey ascending:ascending inQueue:queue error:error condition:condition resultSetHandler:^(__unsafe_unretained Class cls, FMResultSet *set, NSDictionary<NSString *,DWPrefix_YYClassPropertyInfo *> *validProInfos, NSDictionary *databaseMap, NSMutableArray *resultArr, BOOL *stop, BOOL *returnNil, NSError *__autoreleasing *error) {
        id tmp = [cls new];
        if (!tmp) {
            NSError * err = errorWithMessage(@"Invalid Class who is Nil.", 10017);
            safeLinkError(error, err);
            *stop = YES;
            *returnNil = YES;
            return;
        }
        __block BOOL validValue = NO;
        [validProInfos enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, DWPrefix_YYClassPropertyInfo * _Nonnull obj, BOOL * _Nonnull stop) {
            if (obj.name.length) {
                NSString * name = propertyInfoTblName(obj, databaseMap);
                if (name.length) {
                    id value = [set objectForColumn:name];
                    modelSetValueWithPropertyInfo(tmp, obj, value);
                    validValue = YES;
                }
            }
        }];
        if (validValue) {
            NSNumber * Dw_id = [set objectForColumn:kUniqueID];
            if (Dw_id) {
                SetDw_idForModel(tmp, Dw_id);
            }
            [resultArr addObject:tmp];
        }
    }];
}


-(NSInteger)dw_queryTableForCountWithTableName:(NSString *)tblName inQueue:(FMDatabaseQueue *)queue error:(NSError *__autoreleasing *)error condition:(void(^)(DWDatabaseConditionMaker * maker))condition {
    if (!condition) {
        return -1;
    }
    NSArray * ret = [self dw_queryTableWithModel:nil tableName:tblName conditionMap:nil keys:nil limit:0 offset:0 orderKey:nil ascending:YES inQueue:queue error:error condition:condition resultSetHandler:^(__unsafe_unretained Class cls, FMResultSet *set, NSDictionary<NSString *,DWPrefix_YYClassPropertyInfo *> *validProInfos, NSDictionary *databaseMap, NSMutableArray *resultArr, BOOL *stop, BOOL *returnNil, NSError *__autoreleasing *error) {
        [resultArr addObject:@1];
    }];
    
    if (!ret) {
        return -1;
    }
    return ret.count;
}

-(BOOL)validateConfiguration:(DWDatabaseConfiguration *)conf considerTableName:(BOOL)consider error:(NSError * __autoreleasing *)error {
    if (!conf) {
        NSError * err = errorWithMessage(@"Invalid conf who is nil.", 10014);
        safeLinkError(error, err);
        return NO;
    }
    if (!conf.dbName.length) {
        NSError * err = errorWithMessage(@"Invalid name whose length is 0.", 10000);
        safeLinkError(error, err);
        return NO;
    }
    if (![self.allDBs.allKeys containsObject:conf.dbName]) {
        NSError * err = errorWithMessage(@"Invalid name who has been not managed by DWDatabase.", 10019);
        safeLinkError(error, err);
        return NO;
    }
    NSString * path = [self.allDBs valueForKey:conf.dbName];
    if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSString * msg = [NSString stringWithFormat:@"There's no local database at %@",path];
        NSError * err = errorWithMessage(msg, 10021);
        safeLinkError(error, err);
        return NO;
    }
    if (!conf.dbQueue || ![self.dbqContainer.allKeys containsObject:conf.dbName]) {
        NSError * err = errorWithMessage(@"Can't not fetch a FMDatabaseQueue", 10004);
        safeLinkError(error, err);
        return NO;
    }
    if (!consider) {
        return YES;
    }
    if (!conf.tableName.length) {
        NSError * err = errorWithMessage(@"Invalid tblName whose length is 0.", 10005);
        safeLinkError(error, err);
        return NO;
    }
    return [self isTableExistWithTableName:conf.tableName configuration:conf error:error];
}

-(FMDatabaseQueue *)openDBQueueWithName:(NSString *)name path:(NSString *)path private:(BOOL)private {
    NSString * saveP = [path stringByDeletingLastPathComponent];
    ///路径不存在先创建路径
    if (![[NSFileManager defaultManager] fileExistsAtPath:saveP]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:saveP withIntermediateDirectories:NO attributes:nil error:nil];
    }
    FMDatabaseQueue * q = [FMDatabaseQueue databaseQueueWithPath:path];
    if (q && !private) {
        ///缓存当前数据库信息
        [self.allDBs_prv setValue:path forKey:name];
        [self.dbqContainer setValue:q forKey:name];
    }
    return q;
}

///模型存数据库需要保存的键值
-(NSArray *)propertysToSaveWithClass:(Class)cls {
    NSString * key = NSStringFromClass(cls);
    if (!key.length) {
        return nil;
    }
    
    ///有缓存取缓存
    NSArray * tmp = self.saveKeysCache[key];
    if (tmp) {
        return tmp;
    }
    
    ///没有则计算
    DWMetaClassInfo * info = [DWMetaClassInfo classInfoFromClass:cls];
    NSArray * allProps = [[info allPropertyInfos] allKeys];
    if (![cls conformsToProtocol:@protocol(DWDatabaseSaveProtocol)]) {
        tmp = allProps;
    } else if ([cls respondsToSelector:@selector(dw_DataBaseWhiteList)]){
        NSArray * whiteProps = [cls dw_DataBaseWhiteList];
        ///如果白名单不为空，返回白名单交集，为空则代表没有属性要存返回空
        if (whiteProps.count) {
            NSMutableSet * all = [NSMutableSet setWithArray:allProps];
            NSSet * white = [NSSet setWithArray:whiteProps];
            [all intersectSet:white];
            tmp = [all allObjects];
        } else {
            tmp = nil;
        }
    } else if ([cls respondsToSelector:@selector(dw_DataBaseBlackList)]) {
        NSArray * blackProps = [cls dw_DataBaseBlackList];
        ///如果黑名单不为空，则返回排除黑名单的集合，为空则返回全部属性
        if (blackProps.count) {
            NSMutableSet * all = [NSMutableSet setWithArray:allProps];
            NSSet * black = [NSSet setWithArray:blackProps];
            [all minusSet:black];
            tmp = [all allObjects];
        } else {
            tmp = allProps;
        }
    } else {
        tmp = allProps;
    }
    
    ///存储缓存
    tmp = tmp ? [tmp copy] :@[];
    self.saveKeysCache[key] = tmp;
    return tmp;
}

///获取类指定键值的propertyInfo
-(NSDictionary *)propertyInfosWithClass:(Class)cls keys:(NSArray *)keys {
    if (!keys.count || !cls) {
        return nil;
    }
    NSMutableDictionary * dic = [NSMutableDictionary dictionaryWithCapacity:0];
    NSDictionary * all = [[DWMetaClassInfo classInfoFromClass:cls] allPropertyInfos];
    [keys enumerateObjectsUsingBlock:^(NSString * obj, NSUInteger idx, BOOL * _Nonnull stop) {
        if ([all.allKeys containsObject:obj] && obj.length) {
            [dic setValue:[all valueForKey:obj] forKey:obj];
        }
    }];
    return [dic copy];
}

///类存表的所有属性信息
-(NSDictionary *)propertyInfosForSaveKeysWithClass:(Class)cls {
    NSString * key = NSStringFromClass(cls);
    if (!key) {
        return nil;
    }
    NSDictionary * infos = [self.saveInfosCache valueForKey:key];
    if (!infos) {
        NSArray * saveKeys = [self propertysToSaveWithClass:cls];
        infos = [self propertyInfosWithClass:cls keys:saveKeys];
        [self.saveInfosCache setValue:infos forKey:key];
    }
    return infos;
}

-(NSString *)sqlCacheKeyWithPrefix:(NSString *)prefix class:(Class)cls tblName:(NSString *)tblName keys:(NSArray <NSString *>*)keys {
    if (!keys.count) {
        return nil;
    }
    NSString * keyString = [keys componentsJoinedByString:@"-"];
    keyString = [NSString stringWithFormat:@"%@-%@-%@-%@",prefix,NSStringFromClass(cls),tblName,keyString];
    return keyString;
}

-(void)configInfos:(NSDictionary <NSString *,DWPrefix_YYClassPropertyInfo *>*)props map:(NSDictionary *)map model:(NSObject *)model validKeysContainer:(NSMutableArray *)validKeys argumentsContaienr:(NSMutableArray *)args appendingString:(NSString *)appending {
    void (^ab)(NSString * _Nonnull key, DWPrefix_YYClassPropertyInfo * _Nonnull obj, BOOL * _Nonnull stop) = nil;
    if (args) {
        ab = ^(NSString * _Nonnull key, DWPrefix_YYClassPropertyInfo * _Nonnull obj, BOOL * _Nonnull stop) {
            if (obj.name) {
                id value = modelValueWithPropertyInfo(model, obj);
                if (value) {
                    NSString * name = propertyInfoTblName(obj, map);
                    if (name.length) {
                        if (appending.length) {
                            name = [name stringByAppendingString:appending];
                        }
                        [validKeys addObject:name];
                        [args addObject:value];
                    }
                }
            }
        };
    } else {
        ab = ^(NSString * _Nonnull key, DWPrefix_YYClassPropertyInfo * _Nonnull obj, BOOL * _Nonnull stop) {
            if (obj.name.length) {
                NSString * name = propertyInfoTblName(obj, map);
                if (name.length) {
                    if (appending.length) {
                        name = [name stringByAppendingString:appending];
                    }
                    [validKeys addObject:name];
                }
            }
        };
    }
    [props enumerateKeysAndObjectsUsingBlock:ab];
}

-(BOOL)supplyFieldIfNeededWithModel:(NSObject *)model configuration:(DWDatabaseConfiguration *)conf error:(NSError *__autoreleasing *)error {
    Class clazz = [model class];
    NSString * validKey = [NSString stringWithFormat:@"%@%@",conf.dbName,conf.tableName];
    if ([DWMetaClassInfo hasValidFieldSupplyForClass:clazz withValidKey:validKey]) {
        return YES;
    }
    NSArray * allKeysInTbl = [self queryAllFieldInTable:YES class:[model class] configuration:conf error:error];
    NSArray * propertyToSaveKey = [self propertysToSaveWithClass:clazz];
    NSMutableSet * saveProSet = [NSMutableSet setWithArray:propertyToSaveKey];
    [saveProSet minusSet:[NSSet setWithArray:allKeysInTbl]];
    if (saveProSet.count == 0) {
        [DWMetaClassInfo validedFieldSupplyForClass:clazz withValidKey:validKey];
        return YES;
    } else {
        __block BOOL success = YES;
        NSDictionary * map = databaseMapFromClass(clazz);
        NSDictionary <NSString *,DWPrefix_YYClassPropertyInfo *>* propertys = [self propertyInfosWithClass:clazz keys:saveProSet.allObjects];
        [propertys enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, DWPrefix_YYClassPropertyInfo * _Nonnull obj, BOOL * _Nonnull stop) {
            ///转化完成的键名及数据类型
            NSString * field = tblFieldStringFromPropertyInfo(obj,map);
            if (field.length) {
                NSString * sql = [NSString stringWithFormat:@"ALTER TABLE %@ ADD COLUMN %@",conf.tableName,field];
                [conf.dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
                    success = [db executeUpdate:sql] && success;
                    safeLinkError(error, db.lastError);
                }];
            } else {
                success = NO;
                *stop = YES;
            }
        }];
        return success;
    }
}


#pragma mark --- tool func ---
///生成一个随机字符串
NS_INLINE NSString * generateUUID() {
    CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
    NSString *uuidString = (__bridge NSString*)CFUUIDCreateString(kCFAllocatorDefault, uuid);
    CFRelease(uuid);
    return uuidString;
}

///默认存储路径
NSString * defaultSavePath() {
    return [[NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) lastObject] stringByAppendingPathComponent:@"DWDatabase"];
}

NS_INLINE void excuteOnDBOperationQueue(DWDatabase * db,dispatch_block_t block) {
    if (!block) {
        return;
    }
    if (dispatch_get_specific(dbOpQKey)) {
        block();
    } else {
        dispatch_sync(db.dbOperationQueue, block);
    }
}

NS_INLINE void asyncExcuteOnDBOperationQueue(DWDatabase * db,dispatch_block_t block) {
    if (!block) {
        return;
    }
    dispatch_async(db.dbOperationQueue, block);
}

NSString * const dbErrorDomain = @"com.DWDatabase.error";
///快速生成NSError
NS_INLINE NSError * errorWithMessage(NSString * msg,NSInteger code) {
    NSDictionary * userInfo = nil;
    if (msg.length) {
        userInfo = @{NSLocalizedDescriptionKey:msg};
    }
    return [NSError errorWithDomain:dbErrorDomain code:code userInfo:userInfo];
}

///安全赋error
NS_INLINE void safeLinkError(NSError * __autoreleasing * error ,NSError * error2Link) {
    if (error != NULL) {
        *error = error2Link;
    }
}

///获取键值转换表
NS_INLINE NSDictionary * databaseMapFromClass(Class cls) {
    NSDictionary * map = nil;
    if ([cls conformsToProtocol:@protocol(DWDatabaseSaveProtocol)] && [cls respondsToSelector:@selector(dw_ModelKeyToDataBaseMap)]) {
        map = [cls dw_ModelKeyToDataBaseMap];
    }
    return map;
}

///获取property对应的表名
static NSString * propertyInfoTblName(DWPrefix_YYClassPropertyInfo * property,NSDictionary * databaseMap) {
    NSString * name = property.tblName;
    if (!name.length) {
        ///取出原字段名，若转换表中存在转换关系，则替换为转换名
        if ([databaseMap.allKeys containsObject:name]) {
            id mapped = [databaseMap valueForKey:name];
            if ([mapped isKindOfClass:[NSString class]]) {
                name = mapped;
            } else {
                name = property.name;
            }
        } else {
            name = property.name;
        }
        property.tblName = name;
    }
    return name;
}

///以propertyInfo生成对应字段信息
static NSString * tblFieldStringFromPropertyInfo(DWPrefix_YYClassPropertyInfo * property,NSDictionary * databaseMap) {
    ///如果属性类型不在支持类型中，则返回nil
    if (!supportSavingWithPropertyInfo(property)) {
        return nil;
    }
    ///取出表字段名
    NSString * name = propertyInfoTblName(property, databaseMap);
    if (!name.length) {
        return nil;
    }

    ///根据不同类型分配不同的数据类型
    switch (property.type & DWPrefix_YYEncodingTypeMask) {
        case DWPrefix_YYEncodingTypeBool:
        case DWPrefix_YYEncodingTypeInt8:
        case DWPrefix_YYEncodingTypeUInt8:
        case DWPrefix_YYEncodingTypeInt16:
        case DWPrefix_YYEncodingTypeUInt16:
        case DWPrefix_YYEncodingTypeInt32:
        case DWPrefix_YYEncodingTypeUInt32:
        case DWPrefix_YYEncodingTypeInt64:
        case DWPrefix_YYEncodingTypeUInt64:
        {
            return [NSString stringWithFormat:@"%@ INTEGER",name];
        }
        case DWPrefix_YYEncodingTypeFloat:
        case DWPrefix_YYEncodingTypeDouble:
        case DWPrefix_YYEncodingTypeLongDouble:
        {
            return [NSString stringWithFormat:@"%@ REAL",name];
        }
        case DWPrefix_YYEncodingTypeObject:
        {
            switch (property.nsType) {
                case DWPrefix_YYEncodingTypeNSString:
                case DWPrefix_YYEncodingTypeNSMutableString:
                case DWPrefix_YYEncodingTypeNSDate:
                case DWPrefix_YYEncodingTypeNSURL:
                {
                    return [NSString stringWithFormat:@"%@ TEXT",name];
                }
                ///由于建表过程中NSNumber具体值尚未确定，无法推断出整形或浮点型，故此处统一转换为浮点型（因此不推荐使用NSNumber类型数据，建议直接使用基本类型数据）
                case DWPrefix_YYEncodingTypeNSNumber:
                {
                    return [NSString stringWithFormat:@"%@ REAL",name];
                }
                case DWPrefix_YYEncodingTypeNSData:
                case DWPrefix_YYEncodingTypeNSMutableData:
                case DWPrefix_YYEncodingTypeNSArray:
                case DWPrefix_YYEncodingTypeNSMutableArray:
                case DWPrefix_YYEncodingTypeNSDictionary:
                case DWPrefix_YYEncodingTypeNSMutableDictionary:
                case DWPrefix_YYEncodingTypeNSSet:
                case DWPrefix_YYEncodingTypeNSMutableSet:
                {
                    return [NSString stringWithFormat:@"%@ BLOB",name];
                }
                default:
                    return nil;
            }
        }
        case DWPrefix_YYEncodingTypeClass:
        case DWPrefix_YYEncodingTypeSEL:
        case DWPrefix_YYEncodingTypeCString:
        {
            return [NSString stringWithFormat:@"%@ TEXT",name];
        }
        default:
            break;
    }
    return nil;
}

///支持存表的属性
static BOOL supportSavingWithPropertyInfo(DWPrefix_YYClassPropertyInfo * property) {
    static NSSet * supportSet = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        supportSet = [NSSet setWithObjects:
                      @(DWPrefix_YYEncodingTypeBool),
                      @(DWPrefix_YYEncodingTypeInt8),
                      @(DWPrefix_YYEncodingTypeUInt8),
                      @(DWPrefix_YYEncodingTypeInt16),
                      @(DWPrefix_YYEncodingTypeUInt16),
                      @(DWPrefix_YYEncodingTypeInt32),
                      @(DWPrefix_YYEncodingTypeUInt32),
                      @(DWPrefix_YYEncodingTypeInt64),
                      @(DWPrefix_YYEncodingTypeUInt64),
                      @(DWPrefix_YYEncodingTypeFloat),
                      @(DWPrefix_YYEncodingTypeDouble),
                      @(DWPrefix_YYEncodingTypeLongDouble),
                      @(DWPrefix_YYEncodingTypeObject),
                      @(DWPrefix_YYEncodingTypeClass),
                      @(DWPrefix_YYEncodingTypeSEL),
                      @(DWPrefix_YYEncodingTypeCString),nil];
    });
    return [supportSet containsObject:@(property.type)];
}

///模型根据propertyInfo取值（用于给FMDB让其落库，故均为FMDB支持的对象类型）
static id modelValueWithPropertyInfo(id model,DWPrefix_YYClassPropertyInfo * property) {
    switch (property.type & DWPrefix_YYEncodingTypeMask) {
        case DWPrefix_YYEncodingTypeBool:
        case DWPrefix_YYEncodingTypeInt8:
        case DWPrefix_YYEncodingTypeUInt8:
        case DWPrefix_YYEncodingTypeInt16:
        case DWPrefix_YYEncodingTypeUInt16:
        case DWPrefix_YYEncodingTypeInt32:
        case DWPrefix_YYEncodingTypeUInt32:
        case DWPrefix_YYEncodingTypeFloat:
        case DWPrefix_YYEncodingTypeDouble:
        {
            id value = [model valueForKey:property.name];
            if ([value isEqual:[NSNull null]]) {
                return @(NAN);
            } else if ([value isKindOfClass:[NSNumber class]]) {
                return value;
            } else if ([value isKindOfClass:[NSString class]]) {
                if ([value containsString:@"."]) {
                    return @([value floatValue]);
                } else {
                    return @([value integerValue]);
                }
            } else {
                return nil;
            }
        }
        ///不支持NAN
        case DWPrefix_YYEncodingTypeInt64:
        case DWPrefix_YYEncodingTypeUInt64:
        {
            id value = [model valueForKey:property.name];
            if ([value isEqual:[NSNull null]]) {
                return @(0);
            } else if ([value isKindOfClass:[NSNumber class]]) {
                return value;
            } else if ([value isKindOfClass:[NSString class]]) {
                if ([value containsString:@"."]) {
                    return @([value floatValue]);
                } else {
                    return @([value integerValue]);
                }
            } else {
                return nil;
            }
        }
        case DWPrefix_YYEncodingTypeLongDouble:
        {
            long double num = ((long double (*)(id, SEL))(void *) objc_msgSend)((id)model, property.getter);
            return [NSNumber numberWithDouble:num];
        }
        case DWPrefix_YYEncodingTypeObject:
        {
            id value = [model valueForKey:property.name];
            switch (property.nsType) {
                case DWPrefix_YYEncodingTypeNSString:
                case DWPrefix_YYEncodingTypeNSMutableString:
                {
                    if ([value isKindOfClass:[NSString class]]) {
                        return [value copy];
                    } else if ([value isKindOfClass:[NSNumber class]]) {
                        return [NSString stringWithFormat:@"%f",[value floatValue]];
                    } else if ([value isKindOfClass:[NSData class]]) {
                        return [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding];
                    } else if ([value isKindOfClass:[NSDate class]]) {
                        return [dateFormatter() stringFromDate:value];
                    } else if ([value isKindOfClass:[NSURL class]]) {
                        return [value absoluteString];
                    } else if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSDictionary class]]) {
                        NSData * dV = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
                        if (!dV) {
                            return nil;
                        }
                        return [[NSString alloc] initWithData:dV encoding:NSUTF8StringEncoding];
                    } else if ([value isKindOfClass:[NSSet class]]) {
                        NSData * dV = [NSJSONSerialization dataWithJSONObject:[value allObjects] options:0 error:nil];
                        if (!dV) {
                            return nil;
                        }
                        return [[NSString alloc] initWithData:dV encoding:NSUTF8StringEncoding];
                    } else {
                        return nil;
                    }
                }
                case DWPrefix_YYEncodingTypeNSNumber:
                {
                    if ([value isEqual:[NSNull null]]) {
                        return @(NAN);
                    } else if ([value isKindOfClass:[NSNumber class]]) {
                        return value;
                    } else if ([value isKindOfClass:[NSString class]]) {
                        if ([value containsString:@"."]) {
                            return @([value floatValue]);
                        } else {
                            return @([value integerValue]);
                        }
                    } else {
                        return nil;
                    }
                }
                case DWPrefix_YYEncodingTypeNSData:
                case DWPrefix_YYEncodingTypeNSMutableData:
                {
                    if ([value isKindOfClass:[NSData class]]) {
                        return [value copy];
                    } else if ([value isKindOfClass:[NSString class]]) {
                        return [value dataUsingEncoding:NSUTF8StringEncoding];
                    } else {
                        return nil;
                    }
                }
                case DWPrefix_YYEncodingTypeNSDate:
                {
                    if ([value isKindOfClass:[NSDate class]]) {
                        return [dateFormatter() stringFromDate:value];
                    } else if ([value isKindOfClass:[NSString class]]) {
                        if ([dateFormatter() dateFromString:value]) {
                            return value;
                        } else {
                            return nil;
                        }
                    } else {
                        return nil;
                    }
                }
                case DWPrefix_YYEncodingTypeNSURL:
                {
                    if ([value isKindOfClass:[NSURL class]]) {
                        return [value absoluteString];
                    } else if ([value isKindOfClass:[NSString class]]) {
                        return value;
                    } else {
                        return nil;
                    }
                }
                case DWPrefix_YYEncodingTypeNSArray:
                case DWPrefix_YYEncodingTypeNSMutableArray:
                case DWPrefix_YYEncodingTypeNSDictionary:
                case DWPrefix_YYEncodingTypeNSMutableDictionary:
                case DWPrefix_YYEncodingTypeNSSet:
                case DWPrefix_YYEncodingTypeNSMutableSet:
                {
                    if ([value isEqual:[NSNull null]]) {
                        return nil;
                    } else if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSDictionary class]] || [value isKindOfClass:[NSSet class]]) {
                        if ([value isKindOfClass:[NSSet class]]) {
                            value = [value allObjects];
                        }
                        return [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
                    } else if ([value isKindOfClass:[NSData class]] || [value isKindOfClass:[NSString class]]) {
                        id tmp = value;
                        if ([tmp isKindOfClass:[NSString class]]) {
                            tmp = [tmp dataUsingEncoding:NSUTF8StringEncoding];
                        }
                        id obj = [NSJSONSerialization JSONObjectWithData:tmp options:0 error:nil];
                        if (obj) {
                            return tmp;
                        } else {
                            return nil;
                        }
                    } else {
                        return nil;
                    }
                }
                default:
                    return nil;
            }
        }
        case DWPrefix_YYEncodingTypeClass:
        {
            id value = ((Class (*)(id, SEL))(void *) objc_msgSend)((id)model, property.getter);
            if ([value isEqual:[NSNull null]]) {
                return nil;
            } else if ([value isKindOfClass:[NSString class]]) {
                return value;
            } else {
                if (value != Nil) {
                    return NSStringFromClass(value);
                } else {
                    return nil;
                }
            }
        }
        case DWPrefix_YYEncodingTypeSEL:
            return NSStringFromSelector(((SEL (*)(id, SEL))(void *) objc_msgSend)((id)model, property.getter));
        case DWPrefix_YYEncodingTypeCString:
            return [NSString stringWithUTF8String:((char * (*)(id, SEL))(void *) objc_msgSend)((id)model, property.getter)];
        default:
            return nil;
    }
}

///根据propertyInfo给模型赋值（用于通过FMDB取出数据库中的值后赋值给模型，故需要将数据转化为模型对应属性的数据类型）
static void modelSetValueWithPropertyInfo(id model,DWPrefix_YYClassPropertyInfo * property,id value) {
    if (!value) {
        return;
    }
    switch (property.type & DWPrefix_YYEncodingTypeMask) {
        case DWPrefix_YYEncodingTypeBool:
        case DWPrefix_YYEncodingTypeInt8:
        case DWPrefix_YYEncodingTypeUInt8:
        case DWPrefix_YYEncodingTypeInt16:
        case DWPrefix_YYEncodingTypeUInt16:
        case DWPrefix_YYEncodingTypeInt32:
        case DWPrefix_YYEncodingTypeUInt32:
        {
            if ([value isEqual:[NSNull null]]) {
                ///如果是NULL则赋NAN
                [model setValue:@(NAN) forKey:property.name];
            } else if ([value isKindOfClass:[NSNumber class]]) {
                [model setValue:value forKey:property.name];
            } else if ([value isKindOfClass:[NSString class]]) {
                NSNumber * numV = @([value integerValue]);
                if (numV) {
                    [model setValue:numV forKey:property.name];
                }
            }
            break;
        }
        case DWPrefix_YYEncodingTypeFloat:
        case DWPrefix_YYEncodingTypeDouble:
        {
            if ([value isEqual:[NSNull null]]) {
                ///如果是NULL则赋NAN
                [model setValue:@(NAN) forKey:property.name];
            } else if ([value isKindOfClass:[NSNumber class]]) {
                [model setValue:value forKey:property.name];
            } else if ([value isKindOfClass:[NSString class]]) {
                NSNumber * numV = @(atof([value UTF8String]));
                if (numV) {
                    [model setValue:numV forKey:property.name];
                }
            }
            break;
        }
        ///不支持NAN
        case DWPrefix_YYEncodingTypeInt64:
        case DWPrefix_YYEncodingTypeUInt64:
        {
            if ([value isEqual:[NSNull null]]) {
                ///如果是NULL则赋NAN
                [model setValue:@(0) forKey:property.name];
            } else if ([value isKindOfClass:[NSNumber class]]) {
                [model setValue:value forKey:property.name];
            } else if ([value isKindOfClass:[NSString class]]) {
                NSNumber * numV = @(atoll([value UTF8String]));
                if (numV) {
                    [model setValue:numV forKey:property.name];
                }
            }
            break;
        }
        ///这个类型不支持KVC
        case DWPrefix_YYEncodingTypeLongDouble:
        {
            long double numV = 0;
            BOOL valid = YES;
            if ([value isEqual:[NSNull null]]) {
                numV = NAN;
            } else if ([value isKindOfClass:[NSNumber class]]) {
                numV = [value longLongValue];
            } else if ([value isKindOfClass:[NSString class]]) {
                numV = atof(([value UTF8String]));
            } else {
                valid = NO;
            }
            if (valid) {
                ((void (*)(id, SEL, long double))(void *) objc_msgSend)((id)model, property.setter, numV);
            }
            break;
        }
        case DWPrefix_YYEncodingTypeObject:
        {
            ///FMDB中仅可能取出NSString/NSData/NSNumber/NSNull
            switch (property.nsType) {
                case DWPrefix_YYEncodingTypeNSString:
                case DWPrefix_YYEncodingTypeNSMutableString:
                {
                    if ([value isKindOfClass:[NSString class]]) {
                        if (property.nsType == DWPrefix_YYEncodingTypeNSString) {
                            [model setValue:value forKey:property.name];
                        } else {
                            [model setValue:[value mutableCopy] forKey:property.name];
                        }
                    } else if ([value isKindOfClass:[NSNumber class]]) {
                        NSString * strV = [((NSNumber *)value) stringValue];
                        if (property.nsType == DWPrefix_YYEncodingTypeNSString) {
                            [model setValue:strV forKey:property.name];
                        } else {
                            [model setValue:[strV mutableCopy] forKey:property.name];
                        }
                    } else if ([value isKindOfClass:[NSData class]]) {
                        NSString * strV = [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding];
                        if (strV) {
                            if (property.nsType == DWPrefix_YYEncodingTypeNSString) {
                                [model setValue:strV forKey:property.name];
                            } else {
                                [model setValue:[strV mutableCopy] forKey:property.name];
                            }
                        }
                    }
                    break;
                }
                case DWPrefix_YYEncodingTypeNSNumber:
                {
                    if ([value isEqual:[NSNull null]]) {
                        [model setValue:@(NAN) forKey:property.name];
                    } else if ([value isKindOfClass:[NSNumber class]]) {
                        [model setValue:value forKey:property.name];
                    } else if ([value isKindOfClass:[NSString class]]) {
                        NSNumber * numV = @(atof([value UTF8String]));
                        if (numV) {
                            [model setValue:numV forKey:property.name];
                        }
                    }
                    break;
                }
                case DWPrefix_YYEncodingTypeNSData:
                case DWPrefix_YYEncodingTypeNSMutableData:
                {
                    if ([value isKindOfClass:[NSData class]]) {
                        if (property.nsType == DWPrefix_YYEncodingTypeNSData) {
                            [model setValue:value forKey:property.name];
                        } else {
                            [model setValue:[value mutableCopy] forKey:property.name];
                        }
                    } else if ([value isKindOfClass:[NSString class]]) {
                        NSData *dataV = [(NSString *)value dataUsingEncoding:NSUTF8StringEncoding];
                        if (dataV) {
                            if (property.nsType == DWPrefix_YYEncodingTypeNSData) {
                                [model setValue:dataV forKey:property.name];
                            } else {
                                [model setValue:[dataV mutableCopy] forKey:property.name];
                            }
                        }
                    }
                    break;
                }
                case DWPrefix_YYEncodingTypeNSDate:
                {
                    if ([value isKindOfClass:[NSDate class]]) {
                        [model setValue:value forKey:property.name];
                    } else if ([value isKindOfClass:[NSString class]]) {
                        NSDate * dataStr = [dateFormatter() dateFromString:value];
                        if (dataStr) {
                            [model setValue:dataStr forKey:property.name];
                        }
                    }
                    break;
                }
                case DWPrefix_YYEncodingTypeNSURL:
                {
                    if ([value isKindOfClass:[NSURL class]]) {
                        [model setValue:value forKey:property.name];
                    } else if ([value isKindOfClass:[NSString class]]) {
                        NSURL * url = [NSURL URLWithString:value];
                        if (url) {
                            [model setValue:url forKey:property.name];
                        }
                    }
                    break;
                }
                case DWPrefix_YYEncodingTypeNSArray:
                case DWPrefix_YYEncodingTypeNSMutableArray:
                case DWPrefix_YYEncodingTypeNSDictionary:
                case DWPrefix_YYEncodingTypeNSMutableDictionary:
                case DWPrefix_YYEncodingTypeNSSet:
                case DWPrefix_YYEncodingTypeNSMutableSet:
                {
                    if ([value isEqual:[NSNull null]]) {
                        break;
                    }
                    id aV = value;
                    if ([aV isKindOfClass:[NSData class]]) {
                        aV = [NSJSONSerialization JSONObjectWithData:aV options:(NSJSONReadingAllowFragments) error:nil];
                    }
                    if (!aV) {
                        break;
                    }
                    if (property.nsType == DWPrefix_YYEncodingTypeNSArray || property.nsType == DWPrefix_YYEncodingTypeNSMutableArray) {
                        if ([aV isKindOfClass:[NSArray class]]) {
                            if (property.nsType == DWPrefix_YYEncodingTypeNSArray) {
                                [model setValue:aV forKey:property.name];
                            } else {
                                [model setValue:[aV mutableCopy] forKey:property.name];
                            }
                        }
                    } else if (property.nsType == DWPrefix_YYEncodingTypeNSDictionary || property.nsType == DWPrefix_YYEncodingTypeNSMutableDictionary) {
                        if ([aV isKindOfClass:[NSDictionary class]]) {
                            if (property.nsType == DWPrefix_YYEncodingTypeNSDictionary) {
                                [model setValue:aV forKey:property.name];
                            } else {
                                [model setValue:[aV mutableCopy] forKey:property.name];
                            }
                        }
                    } else {
                        if ([aV isKindOfClass:[NSArray class]]) {
                            aV = [NSSet setWithArray:aV];
                            if ([aV isKindOfClass:[NSSet class]]) {
                                if (property.nsType == DWPrefix_YYEncodingTypeNSSet) {
                                    [model setValue:aV forKey:property.name];
                                } else {
                                    [model setValue:[aV mutableCopy] forKey:property.name];
                                }
                            }
                        }
                    }
                    break;
                }
                default:
                    break;
            }
            break;
        }
        case DWPrefix_YYEncodingTypeClass:
        {
            if ([value isKindOfClass:[NSString class]]) {
                ((void (*)(id, SEL, Class))(void *) objc_msgSend)((id)model, property.setter, (Class)NSClassFromString(value));
            }
            break;
        }
        case DWPrefix_YYEncodingTypeSEL:
        {
            if ([value isKindOfClass:[NSString class]]) {
                ((void (*)(id, SEL, SEL))(void *) objc_msgSend)((id)model, property.setter, (SEL)NSSelectorFromString(value));
            }
            break;
        }
        case DWPrefix_YYEncodingTypeCString:
        {
            if ([value isKindOfClass:[NSString class]]) {
                ((void (*)(id, SEL,const char *))(void *) objc_msgSend)((id)model, property.setter, [value UTF8String]);
            }
            break;
        }
        default:
            break;
    }
}

///时间转换格式化
NS_INLINE NSDateFormatter *dateFormatter(){
    static NSDateFormatter * formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    return formatter;
}

///获取额外配置字典
NS_INLINE NSMutableDictionary * additionalConfigFromModel(NSObject * model) {
    NSMutableDictionary * additionalConf = objc_getAssociatedObject(model, kAdditionalConfKey);
    if (!additionalConf) {
        additionalConf = [NSMutableDictionary dictionaryWithCapacity:0];
        objc_setAssociatedObject(model, kAdditionalConfKey, additionalConf, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return additionalConf;
}

///获取id
NS_INLINE NSNumber * Dw_idFromModel(NSObject * model) {
    return [additionalConfigFromModel(model) valueForKey:kDwIdKey];
}

///设置id
NS_INLINE void SetDw_idForModel(NSObject * model,NSNumber * dw_id) {
    [additionalConfigFromModel(model) setValue:dw_id forKey:kDwIdKey];
}

///获取两个数组的交集
NS_INLINE NSArray * intersectionOfArray(NSArray * arr1,NSArray * arr2) {
    if (!arr1.count || !arr2.count) {
        return nil;
    } else {
        NSMutableSet * set1 = [NSMutableSet setWithArray:arr1];
        NSSet * set2 = [NSSet setWithArray:arr2];
        [set1 intersectSet:set2];
        return [set1 allObjects];
    }
}

#pragma mark --- singleton ---
static DWDatabase * db = nil;
+(instancetype)shareDB {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        db = [[self alloc] init_prv];
    });
    return db;
}

+(instancetype)allocWithZone:(struct _NSZone *)zone {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        db = [super allocWithZone:zone];
    });
    return db;
}

#pragma mark --- override ---
-(instancetype)init_prv {
    if (self = [super init]) {
        _dbOperationQueue = dispatch_queue_create("com.DWDatabase.DBOperationQueue", NULL);
        dispatch_queue_set_specific(_dbOperationQueue, dbOpQKey, &dbOpQKey, NULL);
    }
    return self;
}

-(instancetype)init {
    NSAssert(NO, @"Don't call init.Use 'shareDB' instead.");
    return nil;
}

#pragma mark --- setter/getter ---
-(NSDictionary *)allDBs {
    return [self.allDBs_prv copy];
}

-(NSMutableDictionary *)allDBs_prv {
    if (!_allDBs_prv) {
        _allDBs_prv = [NSMutableDictionary dictionaryWithCapacity:0];
    }
    return _allDBs_prv;
}

-(NSMutableDictionary *)dbqContainer {
    if (!_dbqContainer) {
        _dbqContainer = [NSMutableDictionary dictionaryWithCapacity:0];
    }
    return _dbqContainer;
}

-(NSMutableDictionary *)saveKeysCache {
    if (!_saveKeysCache) {
        _saveKeysCache = [NSMutableDictionary dictionaryWithCapacity:0];
    }
    return _saveKeysCache;
}

-(NSMutableDictionary *)saveInfosCache {
    if (!_saveInfosCache) {
        _saveInfosCache = [NSMutableDictionary dictionaryWithCapacity:0];
    }
    return _saveInfosCache;
}

-(NSMutableDictionary *)sqlsCache {
    if (!_sqlsCache) {
        _sqlsCache = [NSMutableDictionary dictionaryWithCapacity:0];
    }
    return _sqlsCache;
}
@end
#pragma mark --------- DWDatabase结束 ---------
