//
//  MPAppDelegate.m
//  MasterPassword
//
//  Created by Maarten Billemont on 24/11/11.
//  Copyright (c) 2011 Lyndir. All rights reserved.
//

#import <objc/runtime.h>
#import "MPAppDelegate_Store.h"

@implementation MPAppDelegate_Shared (Store)

static char privateManagedObjectContextKey, mainManagedObjectContextKey;

#pragma mark - Core Data setup

+ (NSManagedObjectContext *)managedObjectContextForThreadIfReady {

    NSManagedObjectContext *mainManagedObjectContext = [[self get] mainManagedObjectContextIfReady];
    if ([[NSThread currentThread] isMainThread])
        return mainManagedObjectContext;
    
    NSManagedObjectContext *threadManagedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSConfinementConcurrencyType];
    threadManagedObjectContext.parentContext = mainManagedObjectContext;

    return threadManagedObjectContext;
}

+ (BOOL)managedObjectContextPerformBlock:(void (^)(NSManagedObjectContext *))mocBlock {

    NSManagedObjectContext *mainManagedObjectContext = [[self get] mainManagedObjectContextIfReady];
    if (!mainManagedObjectContext)
        return NO;

    NSManagedObjectContext *moc = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    moc.parentContext = mainManagedObjectContext;
    [moc performBlock:^{
        mocBlock(moc);
    }];

    return YES;
}

+ (BOOL)managedObjectContextPerformBlockAndWait:(void (^)(NSManagedObjectContext *))mocBlock {

    NSManagedObjectContext *mainManagedObjectContext = [[self get] mainManagedObjectContextIfReady];
    if (!mainManagedObjectContext)
        return NO;

    NSManagedObjectContext *moc = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    moc.parentContext = mainManagedObjectContext;
    [moc performBlockAndWait:^{
        mocBlock(moc);
    }];

    return YES;
}

- (NSManagedObjectContext *)mainManagedObjectContextIfReady {
    
    if (![self privateManagedObjectContextIfReady])
        return nil;
    
    return objc_getAssociatedObject(self, &mainManagedObjectContextKey);
}

- (NSManagedObjectContext *)privateManagedObjectContextIfReady {

    NSManagedObjectContext *privateManagedObjectContext = objc_getAssociatedObject(self, &privateManagedObjectContextKey);
    if (!privateManagedObjectContext) {
        privateManagedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
        [privateManagedObjectContext performBlockAndWait:^{
            privateManagedObjectContext.mergePolicy                = NSMergeByPropertyObjectTrumpMergePolicy;
            privateManagedObjectContext.persistentStoreCoordinator = self.storeManager.persistentStoreCoordinator;
        }];

        NSManagedObjectContext *mainManagedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        mainManagedObjectContext.parentContext = privateManagedObjectContext;

        objc_setAssociatedObject(self, &privateManagedObjectContextKey, privateManagedObjectContext, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(self, &mainManagedObjectContextKey, mainManagedObjectContext, OBJC_ASSOCIATION_RETAIN);
    }

    if (![privateManagedObjectContext.persistentStoreCoordinator.persistentStores count])
        // Store not available yet.
        return nil;

    return privateManagedObjectContext;
}

- (void)migrateStoreForManager:(UbiquityStoreManager *)storeManager {

    NSNumber *cloudEnabled = [[NSUserDefaults standardUserDefaults] objectForKey:@"iCloudEnabledKey"];
    if (!cloudEnabled)
        // No old data to migrate.
        return;

    if ([cloudEnabled boolValue]) {
        if ([storeManager cloudSafeForSeeding]) {
            NSString *uuid                      = [[NSUserDefaults standardUserDefaults] stringForKey:@"LocalUUIDKey"];
            NSURL    *cloudContainerURL         = [[NSFileManager defaultManager] URLForUbiquityContainerIdentifier:@"HL3Q45LX9N.com.lyndir.lhunath.MasterPassword.shared"];
            NSURL    *newCloudStoreURL          = [storeManager URLForCloudStore];
            NSURL    *newCloudContentURL        = [storeManager URLForCloudContent];
            //NSURL  *oldCloudContentURL        = [[cloudContainerURL URLByAppendingPathComponent:@"Data" isDirectory:YES]
            //                                                        URLByAppendingPathComponent:uuid isDirectory:YES];
            NSURL    *oldCloudStoreDirectoryURL = [cloudContainerURL URLByAppendingPathComponent:@"Database.nosync" isDirectory:YES];
            NSURL    *oldCloudStoreURL          = [[oldCloudStoreDirectoryURL URLByAppendingPathComponent:uuid isDirectory:NO]
                                                                              URLByAppendingPathExtension:@"sqlite"];
            if (![[NSFileManager defaultManager] fileExistsAtPath:oldCloudStoreURL.path isDirectory:NO]) {
                // No old store to migrate from, cannot migrate.
                wrn(@"Cannot migrate cloud store, old store not found at: %@", oldCloudStoreURL.path);
                return;
            }

            NSError      *error                = nil;
            NSDictionary *oldCloudStoreOptions = @{
             // This is here in an attempt to have iCloud recreate the old store file from
             // the baseline and transaction logs from the iCloud account.
             // In my tests however only the baseline was used to recreate the store which then ended up being empty.
             /*NSPersistentStoreUbiquitousContentNameKey    : uuid,
             NSPersistentStoreUbiquitousContentURLKey     : oldCloudContentURL,*/
             // So instead, we'll just open up the old store as read-only, if it exists.
             NSReadOnlyPersistentStoreOption              : @YES,
             NSMigratePersistentStoresAutomaticallyOption : @YES,
             NSInferMappingModelAutomaticallyOption       : @YES};
            NSDictionary *newCloudStoreOptions = @{
             NSPersistentStoreUbiquitousContentNameKey    : [storeManager valueForKey:@"contentName"],
             NSPersistentStoreUbiquitousContentURLKey     : newCloudContentURL,
             NSMigratePersistentStoresAutomaticallyOption : @YES,
             NSInferMappingModelAutomaticallyOption       : @YES};

            // Create the directory to hold the new cloud store.
            // This is only necessary if we want to try to rebuild the old store.  See comment above about how that failed.
            //if (![[NSFileManager defaultManager] createDirectoryAtPath:oldCloudStoreDirectoryURL.path
            //                               withIntermediateDirectories:YES attributes:nil error:&error])
            //err(@"While creating directory for old cloud store: %@", error);
            if (![[NSFileManager defaultManager] createDirectoryAtPath:[storeManager URLForCloudStoreDirectory].path
                                           withIntermediateDirectories:YES attributes:nil error:&error]) {
                err(@"While creating directory for new cloud store: %@", error);
                return;
            }

            NSManagedObjectModel         *model = [NSManagedObjectModel mergedModelFromBundles:nil];
            NSPersistentStoreCoordinator *psc   = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];

            // Open the old cloud store.
            NSPersistentStore *oldStore = [psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:oldCloudStoreURL
                                                                  options:oldCloudStoreOptions error:&error];
            if (!oldStore) {
                err(@"While opening old store for migration %@: %@", oldCloudStoreURL.path, error);
                return;
            }

            // Migrate to the new cloud store.
            if (![psc migratePersistentStore:oldStore toURL:newCloudStoreURL options:newCloudStoreOptions withType:NSSQLiteStoreType
                                       error:&error]) {
                err(@"While migrating cloud store from %@ -> %@: %@", oldCloudStoreURL.path, newCloudStoreURL.path, error);
                return;
            }

            // Clean-up.
            if (![psc removePersistentStore:[psc.persistentStores lastObject] error:&error])
                err(@"While removing the migrated store from the store context: %@", error);
            if (![[NSFileManager defaultManager] removeItemAtURL:oldCloudStoreURL error:&error])
                err(@"While deleting the old cloud store: %@", error);
        }
    } else {
        NSURL *applicationFilesDirectory = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory
                                                                                   inDomains:NSUserDomainMask] lastObject];
        NSURL *oldLocalStoreURL          = [[applicationFilesDirectory URLByAppendingPathComponent:@"MasterPassword" isDirectory:NO]
                                                                       URLByAppendingPathExtension:@"sqlite"];
        NSURL *newLocalStoreURL          = [storeManager URLForLocalStore];
        if ([[NSFileManager defaultManager] fileExistsAtPath:oldLocalStoreURL.path isDirectory:NO] &&
         ![[NSFileManager defaultManager] fileExistsAtPath:newLocalStoreURL.path isDirectory:NO]) {
            NSError                      *error    = nil;
            NSDictionary                 *options  = @{
             NSMigratePersistentStoresAutomaticallyOption : @YES,
             NSInferMappingModelAutomaticallyOption       : @YES};
            NSManagedObjectModel         *model    = [NSManagedObjectModel mergedModelFromBundles:nil];
            NSPersistentStoreCoordinator *psc      = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
            
            // Create the directory to hold the new local store.
            if (![[NSFileManager defaultManager] createDirectoryAtPath:[storeManager URLForLocalStoreDirectory].path
                                           withIntermediateDirectories:YES attributes:nil error:&error]) {
                err(@"While creating directory for new local store: %@", error);
                return;
            }

            // Open the old local store.
            NSPersistentStore            *oldStore = [psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil
                                                                                 URL:oldLocalStoreURL options:options error:&error];
            if (!oldStore) {
                err(@"While opening old store for migration %@: %@", oldLocalStoreURL.path, error);
                return;
            }
            
            // Migrate to the new local store.
            if (![psc migratePersistentStore:oldStore toURL:newLocalStoreURL options:options withType:NSSQLiteStoreType error:&error]) {
                err(@"While migrating local store from %@ -> %@: %@", oldLocalStoreURL, newLocalStoreURL, error);
                return;
            }
            
            // Clean-up.
            if (![psc removePersistentStore:[psc.persistentStores lastObject] error:&error])
                err(@"While removing the migrated store from the store context: %@", error);

            if (![[NSFileManager defaultManager] removeItemAtURL:oldLocalStoreURL error:&error])
                err(@"While deleting the old local store: %@", error);
        }
    }
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"LocalUUIDKey"];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"iCloudEnabledKey"];
}

- (UbiquityStoreManager *)storeManager {

    static UbiquityStoreManager *storeManager = nil;
    if (storeManager)
        return storeManager;

    storeManager = [[UbiquityStoreManager alloc] initStoreNamed:nil withManagedObjectModel:nil localStoreURL:nil
                                            containerIdentifier:@"HL3Q45LX9N.com.lyndir.lhunath.MasterPassword.shared"
#if TARGET_OS_IPHONE
                                         additionalStoreOptions:@{
                                          NSPersistentStoreFileProtectionKey : NSFileProtectionComplete
                                         }];
#else
                                         additionalStoreOptions:nil];
#endif
    storeManager.delegate = self;

    // Migrate old store to new store location.
    [self migrateStoreForManager:storeManager];

    [[NSNotificationCenter defaultCenter] addObserverForName:UbiquityManagedStoreDidChangeNotification
                                                      object:storeManager queue:nil
                                                  usingBlock:^(NSNotification *note) {
                                                      objc_setAssociatedObject(self, &privateManagedObjectContextKey, nil, OBJC_ASSOCIATION_RETAIN);
                                                  }];
    [[NSNotificationCenter defaultCenter] addObserverForName:MPCheckConfigNotification object:nil queue:nil usingBlock:
     ^(NSNotification *note) {
         if ([[MPConfig get].iCloud boolValue] != [self.storeManager cloudEnabled])
             self.storeManager.cloudEnabled = [[MPConfig get].iCloud boolValue];
     }];
#if TARGET_OS_IPHONE
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification
                                                      object:[UIApplication sharedApplication] queue:nil
                                                  usingBlock:^(NSNotification *note) {
                                                      [self saveContexts];
                                                  }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification
                                                      object:[UIApplication sharedApplication] queue:nil
                                                  usingBlock:^(NSNotification *note) {
                                                      [self saveContexts];
                                                  }];
#else
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationWillTerminateNotification
                                                      object:[NSApplication sharedApplication] queue:nil
                                                  usingBlock:^(NSNotification *note) {
                                                      [self saveContexts];
                                                  }];
#endif

    return storeManager;
}

- (void)saveContexts {

    NSManagedObjectContext *mainManagedObjectContext = objc_getAssociatedObject(self, &mainManagedObjectContextKey);
    [mainManagedObjectContext performBlockAndWait:^{
        NSError *error = nil;
        if (![mainManagedObjectContext save:&error])
            err(@"While saving main context: %@", error);
    }];

    NSManagedObjectContext *privateManagedObjectContext = [self privateManagedObjectContextIfReady];
    [privateManagedObjectContext performBlockAndWait:^{
        NSError *error = nil;
        if (![privateManagedObjectContext save:&error])
        err(@"While saving private context: %@", error);
    }];
}

#pragma mark - UbiquityStoreManagerDelegate

- (NSManagedObjectContext *)managedObjectContextForUbiquityStoreManager:(UbiquityStoreManager *)usm {

    return [self privateManagedObjectContextIfReady];
}

- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager log:(NSString *)message {

    dbg(@"[StoreManager] %@", message);
}

- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager didSwitchToCloud:(BOOL)cloudEnabled {

    // manager.cloudEnabled is more reliable (eg. iOS' MPAppDelegate tampers with didSwitch a bit)
    cloudEnabled = manager.cloudEnabled;
    inf(@"Using iCloud? %@", cloudEnabled? @"YES": @"NO");

#ifdef TESTFLIGHT_SDK_VERSION
    [TestFlight passCheckpoint:cloudEnabled? MPCheckpointCloudEnabled: MPCheckpointCloudDisabled];
#endif
#ifdef LOCALYTICS
    [[LocalyticsSession sharedLocalyticsSession] tagEvent:MPCheckpointCloud attributes:@{
    @"enabled": cloudEnabled? @"YES": @"NO"
    }];
#endif

    [MPConfig get].iCloud = @(cloudEnabled);
}

- (void)ubiquityStoreManager:(UbiquityStoreManager *)manager didEncounterError:(NSError *)error cause:(UbiquityStoreManagerErrorCause)cause
                     context:(id)context {

    err(@"StoreManager: cause=%d, context=%@, error=%@", cause, context, error);

#ifdef TESTFLIGHT_SDK_VERSION
    [TestFlight passCheckpoint:PearlString(MPCheckpointMPErrorUbiquity @"_%d", cause)];
#endif
#ifdef LOCALYTICS
    [[LocalyticsSession sharedLocalyticsSession] tagEvent:MPCheckpointMPErrorUbiquity attributes:@{
    @"cause": @(cause),
    @"error.domain": error.domain,
    @"error.code": @(error.code)
    }];
#endif

    switch (cause) {
        case UbiquityStoreManagerErrorCauseDeleteStore:
        case UbiquityStoreManagerErrorCauseCreateStorePath:
        case UbiquityStoreManagerErrorCauseClearStore:
            break;
        case UbiquityStoreManagerErrorCauseOpenLocalStore: {
            wrn(@"Local store could not be opened: %@", error);

            if (error.code == NSMigrationMissingSourceModelError) {
                wrn(@"Resetting the local store.");

#ifdef TESTFLIGHT_SDK_VERSION
                [TestFlight passCheckpoint:MPCheckpointLocalStoreReset];
#endif
#ifdef LOCALYTICS
                [[LocalyticsSession sharedLocalyticsSession] tagEvent:MPCheckpointLocalStoreReset attributes:nil];
#endif
                [manager deleteLocalStore];

                Throw(@"Local store was reset, application must be restarted to use it.");
            } else
             // Try again.
                [manager persistentStoreCoordinator];
        }
        case UbiquityStoreManagerErrorCauseOpenCloudStore: {
            wrn(@"iCloud store could not be opened: %@", error);

            if (error.code == NSMigrationMissingSourceModelError) {
                wrn(@"Resetting the iCloud store.");

#ifdef TESTFLIGHT_SDK_VERSION
                [TestFlight passCheckpoint:MPCheckpointCloudStoreReset];
#endif
#ifdef LOCALYTICS
                [[LocalyticsSession sharedLocalyticsSession] tagEvent:MPCheckpointCloudStoreReset attributes:nil];
#endif
                [manager deleteCloudStore];
                break;
            } else
             // Try again.
                [manager persistentStoreCoordinator];
        }
        case UbiquityStoreManagerErrorCauseMigrateLocalToCloudStore: {
            wrn(@"Couldn't migrate local store to the cloud: %@", error);
            wrn(@"Resetting the iCloud store.");
            [manager deleteCloudStore];
        };
    }
}

#pragma mark - Import / Export

- (MPImportResult)importSites:(NSString *)importedSitesString
            askImportPassword:(NSString *(^)(NSString *userName))importPassword
              askUserPassword:(NSString *(^)(NSString *userName, NSUInteger importCount, NSUInteger deleteCount))userPassword {

    // Compile patterns.
    static NSRegularExpression *headerPattern, *sitePattern;
    NSError *error = nil;
    if (!headerPattern) {
        headerPattern = [[NSRegularExpression alloc] initWithPattern:@"^#[[:space:]]*([^:]+): (.*)"
                                                             options:0 error:&error];
        if (error) {
            err(@"Error loading the header pattern: %@", error);
            return MPImportResultInternalError;
        }
    }
    if (!sitePattern) {
        sitePattern = [[NSRegularExpression alloc] initWithPattern:@"^([^[:space:]]+)[[:space:]]+([[:digit:]]+)[[:space:]]+([[:digit:]]+)(:[[:digit:]]+)?[[:space:]]+([^\t]+)\t(.*)"
                                                           options:0 error:&error];
        if (error) {
            err(@"Error loading the site pattern: %@", error);
            return MPImportResultInternalError;
        }
    }

    // Get a MOC.
    NSAssert(![[NSThread currentThread] isMainThread], @"This method should not be invoked from the main thread.");
    NSManagedObjectContext *moc;
    while (!(moc = [MPAppDelegate_Shared managedObjectContextForThreadIfReady]))
        usleep((useconds_t)(USEC_PER_SEC * 0.2));

    // Parse import data.
    inf(@"Importing sites.");
    __block MPUserEntity *user = nil;
    id<MPAlgorithm> importAlgorithm = nil;
    NSString *importBundleVersion = nil, *importUserName = nil;
    NSData *importKeyID = nil;
    BOOL headerStarted = NO, headerEnded = NO, clearText = NO;
    NSArray        *importedSiteLines    = [importedSitesString componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableSet   *elementsToDelete     = [NSMutableSet set];
    NSMutableArray *importedSiteElements = [NSMutableArray arrayWithCapacity:[importedSiteLines count]];
    NSFetchRequest *elementFetchRequest  = [NSFetchRequest fetchRequestWithEntityName:NSStringFromClass([MPElementEntity class])];
    for (NSString  *importedSiteLine in importedSiteLines) {
        if ([importedSiteLine hasPrefix:@"#"]) {
            // Comment or header
            if (!headerStarted) {
                if ([importedSiteLine isEqualToString:@"##"])
                    headerStarted = YES;
                continue;
            }
            if (headerEnded)
                continue;
            if ([importedSiteLine isEqualToString:@"##"]) {
                headerEnded = YES;
                continue;
            }

            // Header
            if ([headerPattern numberOfMatchesInString:importedSiteLine options:0 range:NSMakeRange(0, [importedSiteLine length])] != 1) {
                err(@"Invalid header format in line: %@", importedSiteLine);
                return MPImportResultMalformedInput;
            }
            NSTextCheckingResult *headerElements = [[headerPattern matchesInString:importedSiteLine options:0
                                                                             range:NSMakeRange(0, [importedSiteLine length])] lastObject];
            NSString             *headerName     = [importedSiteLine substringWithRange:[headerElements rangeAtIndex:1]];
            NSString             *headerValue    = [importedSiteLine substringWithRange:[headerElements rangeAtIndex:2]];
            if ([headerName isEqualToString:@"User Name"]) {
                importUserName = headerValue;

                NSFetchRequest *userFetchRequest = [NSFetchRequest fetchRequestWithEntityName:NSStringFromClass([MPUserEntity class])];
                userFetchRequest.predicate = [NSPredicate predicateWithFormat:@"name == %@", importUserName];
                NSArray *users = [moc executeFetchRequest:userFetchRequest error:&error];
                if (!users) {
                    err(@"While looking for user: %@, error: %@", importUserName, error);
                    return MPImportResultInternalError;
                }
                if ([users count] > 1) {
                    err(@"While looking for user: %@, found more than one: %lu", importUserName, (unsigned long)[users count]);
                    return MPImportResultInternalError;
                }

                user = [users count]? [users lastObject]: nil;
                dbg(@"Found user: %@", [user debugDescription]);
            }
            if ([headerName isEqualToString:@"Key ID"])
                importKeyID                      = [headerValue decodeHex];
            if ([headerName isEqualToString:@"Version"]) {
                importBundleVersion = headerValue;
                importAlgorithm     = MPAlgorithmDefaultForBundleVersion(importBundleVersion);
            }
            if ([headerName isEqualToString:@"Passwords"]) {
                if ([headerValue isEqualToString:@"VISIBLE"])
                    clearText = YES;
            }

            continue;
        }
        if (!headerEnded)
            continue;
        if (!importKeyID || ![importUserName length])
            return MPImportResultMalformedInput;
        if (![importedSiteLine length])
            continue;

        // Site
        if ([sitePattern numberOfMatchesInString:importedSiteLine options:0 range:NSMakeRange(0, [importedSiteLine length])] != 1) {
            err(@"Invalid site format in line: %@", importedSiteLine);
            return MPImportResultMalformedInput;
        }
        NSTextCheckingResult *siteElements  = [[sitePattern matchesInString:importedSiteLine options:0
                                                                      range:NSMakeRange(0, [importedSiteLine length])] lastObject];
        NSString             *lastUsed      = [importedSiteLine substringWithRange:[siteElements rangeAtIndex:1]];
        NSString             *uses          = [importedSiteLine substringWithRange:[siteElements rangeAtIndex:2]];
        NSString             *type          = [importedSiteLine substringWithRange:[siteElements rangeAtIndex:3]];
        NSString             *version       = [importedSiteLine substringWithRange:[siteElements rangeAtIndex:4]];
        NSString             *name          = [importedSiteLine substringWithRange:[siteElements rangeAtIndex:5]];
        NSString             *exportContent = [importedSiteLine substringWithRange:[siteElements rangeAtIndex:6]];

        // Find existing site.
        if (user) {
            elementFetchRequest.predicate = [NSPredicate predicateWithFormat:@"name == %@ AND user == %@", name, user];
            NSArray *existingSites = [moc executeFetchRequest:elementFetchRequest error:&error];
            if (!existingSites) {
                err(@"Lookup of existing sites failed for site: %@, user: %@, error: %@", name, user.userID, error);
                return MPImportResultInternalError;
            } else
                if (existingSites.count)
                dbg(@"Existing sites: %@", existingSites);

            [elementsToDelete addObjectsFromArray:existingSites];
            [importedSiteElements addObject:@[lastUsed, uses, type, version, name, exportContent]];
        }
    }

    // Ask for confirmation to import these sites and the master password of the user.
    inf(@"Importing %lu sites, deleting %lu sites, for user: %@", (unsigned long)[importedSiteElements count], (unsigned long)[elementsToDelete count], [MPUserEntity idFor:importUserName]);
    NSString *userMasterPassword = userPassword(user.name, [importedSiteElements count], [elementsToDelete count]);
    if (!userMasterPassword) {
        inf(@"Import cancelled.");
        return MPImportResultCancelled;
    }
    MPKey *userKey = [MPAlgorithmDefault keyForPassword:userMasterPassword ofUserNamed:user.name];
    if (![userKey.keyID isEqualToData:user.keyID])
        return MPImportResultInvalidPassword;
    __block MPKey *importKey = userKey;
    if ([importKey.keyID isEqualToData:importKeyID])
        importKey = nil;

    // Delete existing sites.
    if (elementsToDelete.count)
        [elementsToDelete enumerateObjectsUsingBlock:^(id obj, BOOL *stop) {
            inf(@"Deleting site: %@, it will be replaced by an imported site.", [obj name]);
            [moc deleteObject:obj];
        }];

    // Make sure there is a user.
    if (!user) {
        user = [NSEntityDescription insertNewObjectForEntityForName:NSStringFromClass([MPUserEntity class])
                                             inManagedObjectContext:moc];
        user.name  = importUserName;
        user.keyID = importKeyID;
        dbg(@"Created User: %@", [user debugDescription]);
    }

    // Import new sites.
    for (NSArray *siteElements in importedSiteElements) {
        NSDate *lastUsed = [[NSDateFormatter rfc3339DateFormatter] dateFromString:[siteElements objectAtIndex:0]];
        NSUInteger    uses    = (unsigned)[[siteElements objectAtIndex:1] integerValue];
        MPElementType type    = (MPElementType)[[siteElements objectAtIndex:2] integerValue];
        NSUInteger    version = (unsigned)[[siteElements objectAtIndex:3] integerValue];
        NSString *name          = [siteElements objectAtIndex:4];
        NSString *exportContent = [siteElements objectAtIndex:5];

        // Create new site.
        MPElementEntity *element = [NSEntityDescription insertNewObjectForEntityForName:[MPAlgorithmForVersion(version) classNameOfType:type]
                                                                 inManagedObjectContext:moc];
        element.name     = name;
        element.user     = user;
        element.type     = type;
        element.uses     = uses;
        element.lastUsed = lastUsed;
        element.version  = version;
        if ([exportContent length]) {
            if (clearText)
                [element importClearTextContent:exportContent usingKey:userKey];
            else {
                if (!importKey)
                    importKey = [importAlgorithm keyForPassword:importPassword(user.name) ofUserNamed:user.name];
                if (![importKey.keyID isEqualToData:importKeyID])
                    return MPImportResultInvalidPassword;

                [element importProtectedContent:exportContent protectedByKey:importKey usingKey:userKey];
            }
        }

        dbg(@"Created Element: %@", [element debugDescription]);
    }

    if (![moc save:&error]) {
        err(@"While saving imported sites: %@", error);
        return MPImportResultInternalError;
    }

    inf(@"Import completed successfully.");
#ifdef TESTFLIGHT_SDK_VERSION
    [TestFlight passCheckpoint:MPCheckpointSitesImported];
#endif
#ifdef LOCALYTICS
    [[LocalyticsSession sharedLocalyticsSession] tagEvent:MPCheckpointSitesImported attributes:nil];
#endif

    return MPImportResultSuccess;
}

- (NSString *)exportSitesShowingPasswords:(BOOL)showPasswords {

    MPUserEntity *activeUser = self.activeUser;
    inf(@"Exporting sites, %@, for: %@", showPasswords? @"showing passwords": @"omitting passwords", activeUser.userID);

    // Header.
    NSMutableString *export = [NSMutableString new];
    [export appendFormat:@"# Master Password site export\n"];
    if (showPasswords)
        [export appendFormat:@"#     Export of site names and passwords in clear-text.\n"];
    else
        [export appendFormat:@"#     Export of site names and stored passwords (unless device-private) encrypted with the master key.\n"];
    [export appendFormat:@"# \n"];
    [export appendFormat:@"##\n"];
    [export appendFormat:@"# Version: %@\n", [PearlInfoPlist get].CFBundleVersion];
    [export appendFormat:@"# User Name: %@\n", activeUser.name];
    [export appendFormat:@"# Key ID: %@\n", [activeUser.keyID encodeHex]];
    [export appendFormat:@"# Date: %@\n", [[NSDateFormatter rfc3339DateFormatter] stringFromDate:[NSDate date]]];
    if (showPasswords)
        [export appendFormat:@"# Passwords: VISIBLE\n"];
    else
        [export appendFormat:@"# Passwords: PROTECTED\n"];
    [export appendFormat:@"##\n"];
    [export appendFormat:@"#\n"];
    [export appendFormat:@"#               Last     Times  Password                  Site\tSite\n"];
    [export appendFormat:@"#               used      used      type                  name\tpassword\n"];

    // Sites.
    for (MPElementEntity *element in activeUser.elements) {
        NSDate *lastUsed = element.lastUsed;
        NSUInteger    uses    = element.uses;
        MPElementType type    = element.type;
        NSUInteger    version = element.version;
        NSString *name    = element.name;
        NSString *content = nil;

        // Determine the content to export.
        if (!(type & MPElementFeatureDevicePrivate)) {
            if (showPasswords)
                content = element.content;
            else
                if (type & MPElementFeatureExportContent)
                    content = element.exportContent;
        }

        [export appendFormat:@"%@  %8ld  %8s  %20s\t%@\n",
                             [[NSDateFormatter rfc3339DateFormatter] stringFromDate:lastUsed], (long)uses,
                             [PearlString(@"%u:%lu", type, (unsigned long)version) UTF8String], [name UTF8String], content
         ? content: @""];
    }

#ifdef TESTFLIGHT_SDK_VERSION
    [TestFlight passCheckpoint:MPCheckpointSitesExported];
#endif
#ifdef LOCALYTICS
    [[LocalyticsSession sharedLocalyticsSession] tagEvent:MPCheckpointSitesExported attributes:nil];
#endif

    return export;
}

@end
