//
//  NotationController.m
//  Notation
//
//  Created by Zachary Schneirov on 12/19/05.
//  Copyright 2005 Zachary Schneirov. All rights reserved.
//

#import "NotationController.h"
#import "NSCollection_utils.h"
#import "NoteObject.h"
#import "DeletedNoteObject.h"
#import "NSString_NV.h"
#import "BufferUtils.h"
#import "GlobalPrefs.h"
#import "NotationPrefs.h"
#import "NoteAttributeColumn.h"
#import "FrozenNotation.h"
#import "NotationFileManager.h"
#import "NotationSyncServiceManager.h"
#import "SyncSessionController.h"
#import "DeletionManager.h"
#import "BookmarksController.h"

@implementation NotationController

NSInteger compareCatalogEntryName(const void *one, const void *two) {
    return (int)CFStringCompare((CFStringRef)((*(NoteCatalogEntry **)one)->filename), 
				(CFStringRef)((*(NoteCatalogEntry **)two)->filename), kCFCompareCaseInsensitive);
}

NSInteger compareCatalogValueNodeID(id *a, id *b) {
	NoteCatalogEntry* aEntry = (NoteCatalogEntry*)[*(id*)a pointerValue];
	NoteCatalogEntry* bEntry = (NoteCatalogEntry*)[*(id*)b pointerValue];
	
    return aEntry->nodeID - bEntry->nodeID;
}

NSInteger compareCatalogValueFileSize(id *a, id *b) {
	NoteCatalogEntry* aEntry = (NoteCatalogEntry*)[*(id*)a pointerValue];
	NoteCatalogEntry* bEntry = (NoteCatalogEntry*)[*(id*)b pointerValue];
	
    return aEntry->logicalSize - bEntry->logicalSize;
}


- (id)init {
    if ([super init]) {
		directoryChangesFound = notesChanged = aliasNeedsUpdating = NO;
		
		allNotes = [[NSMutableArray alloc] init]; //<--the authoritative list of all memory-accessible notes
		deletedNotes = [[NSMutableSet alloc] init];
		labelsListController = [[LabelsListController alloc] init];
		prefsController = [GlobalPrefs defaultPrefs];
		notesListDataSource = [[FastListDataSource alloc] init];
		
		allNotesBuffer = NULL;
		allNotesBufferSize = 0;
		manglingString = currentFilterStr = NULL;
		lastWordInFilterStr = 0;
		selectedNoteIndex = NSNotFound;
		
		subscriptionCallback = NewFNSubscriptionUPP(NotesDirFNSubscriptionProc);
		
		fsCatInfoArray = NULL;
		HFSUniNameArray = NULL;
		catalogEntries = NULL;
		sortedCatalogEntries = NULL;
		catEntriesCount = totalCatEntriesCount = 0;
		
		bzero(&noteDirSubscription, sizeof(FNSubscriptionRef));
		bzero(&noteDatabaseRef, sizeof(FSRef));
		bzero(&noteDirectoryRef, sizeof(FSRef));
		volumeSupportsExchangeObjects = -1;
		
		lastCheckedDateInHours = hoursFromAbsoluteTime(CFAbsoluteTimeGetCurrent());
		blockSize = 0;
		
		lastWriteError = noErr;
		unwrittenNotes = [[NSMutableSet alloc] init];
    }
    return self;
}


- (id)initWithAliasData:(NSData*)data error:(OSStatus*)err {
    OSStatus anErr = noErr;
    
    if (data && (anErr = PtrToHand([data bytes], (Handle*)&aliasHandle, [data length])) == noErr) {
	
	FSRef targetRef;
	Boolean changed;
	
	if ((anErr = FSResolveAliasWithMountFlags(NULL, aliasHandle, &targetRef, &changed, 0)) == noErr) {
	    if ([self initWithDirectoryRef:&targetRef error:&anErr]) {
		aliasNeedsUpdating = changed;
		*err = noErr;
		
		return self;
	    }
	}
    }
    
    *err = anErr;
    
    return nil;
}

- (id)initWithDefaultDirectoryReturningError:(OSStatus*)err {
    FSRef targetRef;
    
    OSStatus anErr = noErr;
    if ((anErr = [NotationController getDefaultNotesDirectoryRef:&targetRef]) == noErr) {
		
		if ([self initWithDirectoryRef:&targetRef error:&anErr]) {
			*err = noErr;
			return self;
		}
    }
    
    *err = anErr;
    
    return nil;
}

- (id)initWithDirectoryRef:(FSRef*)directoryRef error:(OSStatus*)err {
    
    *err = noErr;
    
    if ([self init]) {
		aliasNeedsUpdating = YES; //we don't know if we have an alias yet
		
		noteDirectoryRef = *directoryRef;
		
		//check writable and readable perms, warning user if necessary
		
		//first read cache file
		OSStatus anErr = noErr;
		if ((anErr = [self _readAndInitializeSerializedNotes]) != noErr) {
			*err = anErr;
			return nil;
		}
		
		//set up the directory subscription, if necessary
		//and sync based on notes in directory and their mod. dates
		[self databaseSettingsChangedFromOldFormat:[notationPrefs notesStorageFormat]];
		if (!walWriter) {
			*err = kJournalingError;
			return nil;
		}
		
		[self upgradeDatabaseIfNecessary];
    }
    
    return self;
}

- (id)delegate {
	return delegate;
}

- (void)setDelegate:(id)theDelegate {
	
	delegate = theDelegate;

}

- (void)upgradeDatabaseIfNecessary {
	if (![notationPrefs firstTimeUsed]) {
		
		//upgrade note-text-encodings here if there might exist notes with the wrong encoding (check NotationPrefs values)
		if ([notationPrefs epochIteration] < 2) {
			//this would have to be a database from epoch 1, where the default file-encoding was system-default
			NSLog(@"trying to upgrade note encodings");
			[allNotes makeObjectsPerformSelector:@selector(upgradeToUTF8IfUsingSystemEncoding)];
			//move aside the old database as the new format breaks compatibility
			(void)[self renameAndForgetNoteDatabaseFile:@"Notes & Settings (old version from 2.0b)"];
		}
		if ([notationPrefs epochIteration] < 3) {
			[allNotes makeObjectsPerformSelector:@selector(writeFileDatesAndUpdateTrackingInfo)];
		}
		
		if ([notationPrefs epochIteration] < EPOC_ITERATION) {
			NSLog(@"epociteration was upgraded from %u to %u", [notationPrefs epochIteration], EPOC_ITERATION);
			notesChanged = YES;
			[self flushEverything];
		} else if ([notationPrefs epochIteration] > EPOC_ITERATION) {
			if (NSRunCriticalAlertPanel(NSLocalizedString(@"Warning: this database was created by a newer version of Notational Velocity. Continue anyway?", nil), 
										NSLocalizedString(@"If you make changes, some settings and metadata will be lost.", nil), 
										NSLocalizedString(@"Quit", nil), NSLocalizedString(@"Continue", nil), nil) == NSAlertDefaultReturn);
			exit(0);
		}
	}	
}

//used to ensure a newly-written Notes & Settings file is valid before finalizing the save
//read the file back from disk, deserialize it, decrypt and decompress it, and compare the notes roughly to our current notes
- (NSNumber*)verifyDataAtTemporaryFSRef:(NSValue*)fsRefValue withFinalName:(NSString*)filename {
	
	NSDate *date = [NSDate date];
	
	NSAssert([filename isEqualToString:NotesDatabaseFileName], @"attempting to verify something other than the database");
	
	FSRef *notesFileRef = [fsRefValue pointerValue];
	UInt64 fileSize = 0;
	char *notesData = NULL;
	OSStatus err = noErr, result = noErr;
	if ((err = FSRefReadData(notesFileRef, BlockSizeForNotation(self), &fileSize, (void**)&notesData, forceReadMask)) != noErr)
		return [NSNumber numberWithInt:err];
	
	FrozenNotation *frozenNotation = nil;
	if (!fileSize) {
		result = eofErr;
		goto returnResult;
	}
	NSData *archivedNotation = [[[NSData alloc] initWithBytesNoCopy:notesData length:fileSize freeWhenDone:NO] autorelease];
	@try {
		frozenNotation = [NSKeyedUnarchiver unarchiveObjectWithData:archivedNotation];
	} @catch (NSException *e) {
		NSLog(@"(VERIFY) Error unarchiving notes and preferences from data (%@, %@)", [e name], [e reason]);
		result = kCoderErr;
		goto returnResult;
	}
	//unpack notes using the current NotationPrefs instance (not the just-unarchived one), with which we presumably just used to encrypt it
	NSMutableArray *notesToVerify = [[frozenNotation unpackedNotesWithPrefs:notationPrefs returningError:&err] retain];	
	if (noErr != err) {
		result = err;
		goto returnResult;
	}
	//notes were unpacked--now roughly compare notesToVerify with allNotes, plus deletedNotes and notationPrefs
	if (!notesToVerify || [notesToVerify count] != [allNotes count] || [[frozenNotation deletedNotes] count] != [deletedNotes  count] || 
		[[frozenNotation notationPrefs] notesStorageFormat] != [notationPrefs notesStorageFormat] ||
		[[frozenNotation notationPrefs] hashIterationCount] != [notationPrefs hashIterationCount]) {
		result = kItemVerifyErr;
		goto returnResult;
	}
	unsigned int i;
	for (i=0; i<[notesToVerify count]; i++) {
		if ([[[notesToVerify objectAtIndex:i] contentString] length] != [[[allNotes objectAtIndex:i] contentString] length]) {
			result = kItemVerifyErr;
			goto returnResult;
		}
	}
	
	NSLog(@"verified %u notes in %g s", [notesToVerify count], (float)[[NSDate date] timeIntervalSinceDate:date]);
returnResult:
	if (notesData) free(notesData);
	return [NSNumber numberWithInt:result];
}


- (OSStatus)_readAndInitializeSerializedNotes {

    OSStatus err = noErr;
	if ((err = [self createFileIfNotPresentInNotesDirectory:&noteDatabaseRef forFilename:NotesDatabaseFileName fileWasCreated:nil]) != noErr)
		return err;
	
	UInt64 fileSize = 0;
	char *notesData = NULL;
	if ((err = FSRefReadData(&noteDatabaseRef, BlockSizeForNotation(self), &fileSize, (void**)&notesData, noCacheMask)) != noErr)
		return err;
	
	FrozenNotation *frozenNotation = nil;
	
	if (fileSize > 0) {
		NSData *archivedNotation = [[NSData alloc] initWithBytesNoCopy:notesData length:fileSize freeWhenDone:NO];
		@try {
			frozenNotation = [NSKeyedUnarchiver unarchiveObjectWithData:archivedNotation];
		} @catch (NSException *e) {
			NSLog(@"Error unarchiving notes and preferences from data (%@, %@)", [e name], [e reason]);
			
			if (notesData)
				free(notesData);
			
			//perhaps this shouldn't be an error, but the user should instead have the option of overwriting the DB with a new one?
			return kCoderErr;
		}
	
		[archivedNotation autorelease];
	}
	
	
	[notationPrefs release];
	
	if (!(notationPrefs = [[frozenNotation notationPrefs] retain]))
		notationPrefs = [[NotationPrefs alloc] init];
	[notationPrefs setDelegate:self];
	
	[allNotes release];
	
	syncSessionController = [[SyncSessionController alloc] initWithSyncDelegate:self notationPrefs:notationPrefs];
	
	//frozennotation will work out passwords, keychains, decryption, etc...
	if (!(allNotes = [[frozenNotation unpackedNotesReturningError:&err] retain])) {
		//notes could be nil because the user cancelled password authentication
		//or because they were corrupted, or for some other reason
		if (err != noErr)
			return err;
		
		allNotes = [[NSMutableArray alloc] init];
	} else {
		[allNotes makeObjectsPerformSelector:@selector(setDelegate:) withObject:self];
		//[allNotes makeObjectsPerformSelector:@selector(updateLabelConnectionsAfterDecoding)]; //not until we get an actual tag browser
	}
	
	[deletedNotes release];
	
	if (!(deletedNotes = [[frozenNotation deletedNotes] retain]))
	    deletedNotes = [[NSMutableSet alloc] init];
		
	[prefsController setNotationPrefs:notationPrefs sender:self];
	
	if(notesData)
	    free(notesData);
	
	return noErr;
}

- (BOOL)initializeJournaling {
    
    const UInt32 maxPathSize = 8 * 1024;
    UInt8 *convertedPath = (UInt8*)malloc(maxPathSize * sizeof(UInt8));
    OSStatus err = noErr;
	NSData *walSessionKey = [notationPrefs WALSessionKey];
	
    if ((err = FSRefMakePath(&noteDirectoryRef, convertedPath, maxPathSize)) == noErr) {
		//initialize the journal if necessary
		if (!(walWriter = [[WALStorageController alloc] initWithParentFSRep:(char*)convertedPath encryptionKey:walSessionKey])) {
			//journal file probably already exists, so try to recover it
			WALRecoveryController *walReader = [[[WALRecoveryController alloc] initWithParentFSRep:(char*)convertedPath encryptionKey:walSessionKey] autorelease];
			if (walReader) {
				
				BOOL databaseCouldNotBeFlushed = NO;
				NSDictionary *recoveredNotes = [walReader recoveredNotes];
				if ([recoveredNotes count] > 0) {
					[self processRecoveredNotes:recoveredNotes];
					
					if (![self flushAllNoteChanges]) {
						//we shouldn't continue because the journal is still the sole record of the unsaved notes, so we can't delete it
						//BUT: what if the database can't be verified? We should be able to continue, and just keep adding to the WAL
						//in this case the WAL should be destroyed, re-initialized, and the recovered (and de-duped) notes added back
						NSLog(@"Unable to flush recovered notes back to database");
						databaseCouldNotBeFlushed = YES;
						//goto bail;
					}
				}
				//is there a way that recoverNextObject could fail that would indicate a failure with the file as opposed to simple non-recovery?
				//if so, it perhaps the recoveredNotes method should also return an error condition, to be checked here
				
				//there could be other issues, too (1)
				
				if (![walReader destroyLogFile]) {
					//couldn't delete the log file, so we can't create a new one
					NSLog(@"Unable to delete the old write-ahead-log file");
					goto bail;
				}
				
				if (!(walWriter = [[WALStorageController alloc] initWithParentFSRep:(char*)convertedPath encryptionKey:walSessionKey])) {
					//couldn't create a journal after recovering the old one
					//if databaseCouldNotBeFlushed is true here, then we've potentially lost notes; perhaps exchangeobjects would be better here?
					NSLog(@"Unable to create a new write-ahead-log after deleting the old one");
					goto bail;
				}
				
				if ([recoveredNotes count] > 0) {
					if (databaseCouldNotBeFlushed) {
						//re-add the contents of recoveredNotes to walWriter; LSNs should take care of the order; no need to sort
						//this allows for an ever-growing journal in the case of broken database serialization
						//it should not be an acceptable condition for permanent use; hopefully an update would come soon
						//warn the user, perhaps
						[walWriter writeNoteObjects:[recoveredNotes allValues]];
					}
					[self refilterNotes];
				}
			} else {
				NSLog(@"Unable to recover unsaved notes from write-ahead-log");
				//1) should we let the user attempt to remove it without recovery?
				goto bail;
			}
		}
		[walWriter setDelegate:self];
		
		return YES;
    } else {
		NSLog(@"FSRefMakePath error: %d", err);
		goto bail;
    }
    
bail:
		free(convertedPath);	
    return NO;
}

//stick the newest unique recovered notes into allNotes
- (void)processRecoveredNotes:(NSDictionary*)dict {
    const unsigned int vListBufCount = 16;
    void* keysBuffer[vListBufCount], *valuesBuffer[vListBufCount];
    unsigned int i, count = [dict count];
    
    void **keys = (count <= vListBufCount) ? keysBuffer : (void **)malloc(sizeof(void*) * count);
    void **values = (count <= vListBufCount) ? valuesBuffer : (void **)malloc(sizeof(void*) * count);
    
    if (keys && values && dict) {
	CFDictionaryGetKeysAndValues((CFDictionaryRef)dict, (const void **)keys, (const void **)values);
	
		for (i=0; i<count; i++) {
			
			CFUUIDBytes *objUUIDBytes = (CFUUIDBytes *)keys[i];
			id<SynchronizedNote> obj = (id)values[i];
			
			NSUInteger existingNoteIndex = [allNotes indexOfNoteWithUUIDBytes:objUUIDBytes];
			
			if ([obj isKindOfClass:[DeletedNoteObject class]]) {
				
				if (existingNoteIndex != NSNotFound) {
					
					NoteObject *existingNote = [allNotes objectAtIndex:existingNoteIndex];
					if ([existingNote youngerThanLogObject:obj]) {
						NSLog(@"got a newer deleted note");
						//except that normally the undomanager doesn't exist by this point			
						[self _registerDeletionUndoForNote:existingNote];
						[allNotes removeObjectAtIndex:existingNoteIndex];
						//try to use use the deleted note object instead of allowing _addDeletedNote: to make a new one, to preserve any changes to the syncMD
						[self _addDeletedNote:obj];
						notesChanged = YES;
					} else {
						NSLog(@"got an older deleted note");
					}
				}
			} else if (existingNoteIndex != NSNotFound) {
				
				if ([[allNotes objectAtIndex:existingNoteIndex] youngerThanLogObject:obj]) {
					// NSLog(@"replacing old note with new: %@", [[(NoteObject*)obj contentString] string]);
					
					[(NoteObject*)obj setDelegate:self];
					[(NoteObject*)obj updateLabelConnectionsAfterDecoding];
					[allNotes replaceObjectAtIndex:existingNoteIndex withObject:obj];
					notesChanged = YES;
				} else {
					// NSLog(@"note %@ is not being replaced because its LSN is %u, while the old note's LSN is %u", 
					//  [[(NoteObject*)obj contentString] string], [(NoteObject*)obj logSequenceNumber], [[allNotes objectAtIndex:existingNoteIndex] logSequenceNumber]);
				}
			} else {
				//NSLog(@"Found new note: %@", [(NoteObject*)obj contentString]);
				
				[self _addNote:obj];
				[(NoteObject*)obj updateLabelConnectionsAfterDecoding];
			}
		}
		
	if (keys != keysBuffer)
	    free(keys);
	if (values != valuesBuffer)
	    free(values);
	
    } else {
	NSLog(@"_makeChangesInDictionary: Could not get values or keys!");
    }
}

- (void)closeJournal {
    //remove journal file if we have one
    if (walWriter) {
		if (![walWriter destroyLogFile])
			NSLog(@"couldn't remove wal file--is this an error for note flushing?");
		
		[walWriter release];
		walWriter = nil;	
    }
}

- (void)checkJournalExistence {
    if (walWriter && ![walWriter logFileStillExists])
	[self performSelector:@selector(handleJournalError) withObject:nil afterDelay:0.0];
}

- (void)flushEverything {
	
	//if we could flush the database and there was a journal, then close it
	if ([self flushAllNoteChanges] && walWriter) {
		[self closeJournal];
		
		//re-start the journal if we had one
		if (![self initializeJournaling]) {
			[self performSelector:@selector(handleJournalError) withObject:nil afterDelay:0.0];
		}
	}
}

- (BOOL)flushAllNoteChanges {
    //write only if preferences or notes have been changed
    if (notesChanged || [notationPrefs preferencesChanged]) {
		
		//finish writing notes and/or db journal entries
		[self synchronizeNoteChanges:changeWritingTimer];	
		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(synchronizeNoteChanges:) object:nil];
		
		if (walWriter) {
			if (![walWriter synchronize])
				NSLog(@"Couldn't sync wal file--is this an error for note flushing?");
			[NSObject cancelPreviousPerformRequestsWithTarget:walWriter selector:@selector(synchronize) object:nil];
		}
		
		NSData *serializedData = [FrozenNotation frozenDataWithExistingNotes:allNotes deletedNotes:deletedNotes prefs:notationPrefs];
		if (!serializedData) {
			
			NSLog(@"serialized data is nil!");
			return NO;
		}
		
		//we should have all journal records on disk by now
		if ([self storeDataAtomicallyInNotesDirectory:serializedData withName:NotesDatabaseFileName destinationRef:&noteDatabaseRef 
								   verifyWithSelector:@selector(verifyDataAtTemporaryFSRef:withFinalName:) verificationDelegate:self] != noErr)
			return NO;
		
		[notationPrefs setPreferencesAreStored];
		notesChanged = NO;
		
    }
	
    return YES;
}

- (void)handleJournalError {
    
    //we can be static because the resulting action (exit) is global to the app
    static BOOL displayedAlert = NO;
    
    if (delegate && !displayedAlert) {
	//we already have a delegate, so this must be a result of the format or file changing after initialization
	
	displayedAlert = YES;
	
	[self flushAllNoteChanges];
	
	NSRunAlertPanel(NSLocalizedString(@"Unable to create or access the Interim Note-Changes file. Is another copy of Notational Velocity currently running?",nil), 
			NSLocalizedString(@"Open Console in /Applications/Utilities/ for more information.",nil), NSLocalizedString(@"Quit",nil), NULL, NULL);
	
	
	exit(1);
    }
}

//notation prefs delegate method
- (void)databaseEncryptionSettingsChanged {
	//we _must_ re-init the journal (if fmt is single-db and jrnl exists) in addition to flushing DB
	[self flushEverything];
}

//notation prefs delegate method
- (void)databaseSettingsChangedFromOldFormat:(int)oldFormat {
    OSStatus err = noErr;
	int currentStorageFormat = [notationPrefs notesStorageFormat];
    
	if (!walWriter && ![self initializeJournaling]) {
		[self performSelector:@selector(handleJournalError) withObject:nil afterDelay:0.0];
	}
	
    if (currentStorageFormat == SingleDatabaseFormat) {
		
		[self stopFileNotifications];
		
		/*if (![self initializeJournaling]) {
			[self performSelector:@selector(handleJournalError) withObject:nil afterDelay:0.0];
		}*/
		
    } else {
		//write to disk any unwritten notes; do this before flushing database to make sure that when it is flushed, it gets the new file mod. dates
		//otherwise it would be necessary to set notesChanged = YES; after this method
		
		//also make sure not to write new notes unless changing to a different format; don't rewrite deleted notes upon launch
		if (currentStorageFormat != oldFormat)
			[allNotes makeObjectsPerformSelector:@selector(writeUsingCurrentFileFormatIfNonExistingOrChanged)];

		//flush and close the journal if necessary
		/*if (walWriter) {
			if ([self flushAllNoteChanges])
				[self closeJournal];
		}*/
		//notationPrefs should call flushAllNoteChanges after this method, anyway
				
		if (IsZeros(&noteDirSubscription, sizeof(FNSubscriptionRef))) {
			
			err = FNSubscribe(&noteDirectoryRef, subscriptionCallback, self, kFNNoImplicitAllSubscription | kFNNotifyInBackground, &noteDirSubscription);
			if (err != noErr) {
				NSLog(@"Could not subscribe to changes in notes directory!");
				//just check modification time of directory?
			}
		}
		
		[self synchronizeNotesFromDirectory];
    }
}

- (int)currentNoteStorageFormat {
    return [notationPrefs notesStorageFormat];
}

- (void)stopFileNotifications {
	OSStatus err = noErr;
    if (!IsZeros(&noteDirSubscription, sizeof(FNSubscriptionRef))) {
		
		if ((err = FNUnsubscribe(noteDirSubscription)) != noErr) {
			NSLog(@"Could not unsubscribe from note changes callback: %d", err);
		} else {
			bzero(&noteDirSubscription, sizeof(FNSubscriptionRef));
		}
		
		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(synchronizeNotesFromDirectory) object:nil];
    }
    
}

void NotesDirFNSubscriptionProc(FNMessage message, OptionBits flags, void * refcon, FNSubscriptionRef subscription) {
    //this only works for the Finder and perhaps the navigation manager right now
    if (kFNDirectoryModifiedMessage == message) {
		//NSLog(@"note directory changed");
		if (refcon) {
			[NSObject cancelPreviousPerformRequestsWithTarget:(id)refcon selector:@selector(synchronizeNotesFromDirectory) object:nil];
			[(id)refcon performSelector:@selector(synchronizeNotesFromDirectory) withObject:nil afterDelay:0.0];
		}
		
    } else {
		NSLog(@"we received an FNSubscr. callback and the directory didn't actually change?");
    }
}


- (BOOL)synchronizeNotesFromDirectory {
    if ([self currentNoteStorageFormat] == SingleDatabaseFormat) {
		//NSLog(@"%s: called when storage format is singledatabase", _cmd);
		return NO;
	}
	
    //NSDate *date = [NSDate date];
    if ([self _readFilesInDirectory]) {
		//NSLog(@"read files in directory");
		
		directoryChangesFound = NO;
		if (catEntriesCount && [allNotes count]) {
			[self makeNotesMatchCatalogEntries:sortedCatalogEntries ofSize:catEntriesCount];
		} else {
			unsigned int i;
			
			if (![allNotes count]) {
				//no notes exist, so every file must be new
				for (i=0; i<catEntriesCount; i++) {
					if ([notationPrefs catalogEntryAllowed:sortedCatalogEntries[i]])
						[self addNoteFromCatalogEntry:sortedCatalogEntries[i]];
				}
			}
			
			if (!catEntriesCount) {
				//there is nothing at all in the directory, so remove all the notes
				//we probably shouldn't get here; there should be at least a database file and random .DS_Store-like crap
				[[DeletionManager sharedManager] addDeletedNotes:allNotes];
			}
		}
		
		if (directoryChangesFound) {
			[self resortAllNotes];
		    [self refilterNotes];
		}
		
		//NSLog(@"file sync time: %g, ",[[NSDate date] timeIntervalSinceDate:date]);
		return YES;
    }
    
    return NO;
}

//scour the notes directory for fresh meat
- (BOOL)_readFilesInDirectory {
    
    OSStatus status = noErr;
    FSIterator dirIterator;
    ItemCount totalObjects = 0, dirObjectCount = 0;
    unsigned int i = 0, catIndex = 0;
    
    //something like 16 VM pages used here?
    if (!fsCatInfoArray) fsCatInfoArray = (FSCatalogInfo *)calloc(kMaxFileIteratorCount, sizeof(FSCatalogInfo));
    if (!HFSUniNameArray) HFSUniNameArray = (HFSUniStr255 *)calloc(kMaxFileIteratorCount, sizeof(HFSUniStr255));
	
    if ((status = FSOpenIterator(&noteDirectoryRef, kFSIterateFlat, &dirIterator)) == noErr) {
	//catEntriesCount = 0;
	
        do {
            // Grab a batch of source files to process from the source directory
            status = FSGetCatalogInfoBulk(dirIterator, kMaxFileIteratorCount, &dirObjectCount, NULL,
					  kFSCatInfoNodeFlags | kFSCatInfoFinderInfo | kFSCatInfoContentMod | kFSCatInfoDataSizes | kFSCatInfoNodeID,
					  fsCatInfoArray, NULL, NULL, HFSUniNameArray);
	    
            if ((status == errFSNoMoreItems || status == noErr) && dirObjectCount) {
                status = noErr;
		
		totalObjects += dirObjectCount;
		if (totalObjects > totalCatEntriesCount) {
		    unsigned int oldCatEntriesCount = totalCatEntriesCount;
		    
		    totalCatEntriesCount = totalObjects;
		    catalogEntries = (NoteCatalogEntry *)realloc(catalogEntries, totalObjects * sizeof(NoteCatalogEntry));
		    sortedCatalogEntries = (NoteCatalogEntry **)realloc(sortedCatalogEntries, totalObjects * sizeof(NoteCatalogEntry*));

		    //clear unused memory to make filename and filenameChars null
		    
		    size_t newSpace = (totalCatEntriesCount - oldCatEntriesCount) * sizeof(NoteCatalogEntry);
		    bzero(catalogEntries + oldCatEntriesCount, newSpace);
		}
		
		for (i = 0; i < dirObjectCount; i++) {
		    // Only read files, not directories
		    if (!(fsCatInfoArray[i].nodeFlags & kFSNodeIsDirectoryMask)) { 
			//filter these only for files that will be added
			//that way we can catch changes in files whose format is still being lazily updated
			
			NoteCatalogEntry *entry = &catalogEntries[catIndex];
			HFSUniStr255 *filename = &HFSUniNameArray[i];
			
			entry->fileType = ((FileInfo *)fsCatInfoArray[i].finderInfo)->fileType;
			entry->logicalSize = (UInt32)(fsCatInfoArray[i].dataLogicalSize & 0xFFFFFFFF);
			entry->nodeID = (UInt32)fsCatInfoArray[i].nodeID;
			entry->lastModified = fsCatInfoArray[i].contentModDate;
			
			if (filename->length > entry->filenameCharCount) {
			    entry->filenameCharCount = filename->length;
			    entry->filenameChars = (UniChar*)realloc(entry->filenameChars, entry->filenameCharCount * sizeof(UniChar));
			}
			
			memcpy(entry->filenameChars, filename->unicode, filename->length * sizeof(UniChar));
			
			if (!entry->filename)
			    entry->filename = CFStringCreateMutableWithExternalCharactersNoCopy(NULL, entry->filenameChars, filename->length, entry->filenameCharCount, kCFAllocatorNull);
			else
			    CFStringSetExternalCharactersNoCopy(entry->filename, entry->filenameChars, filename->length, entry->filenameCharCount);
			
			catIndex++;
                    }
                }
		
		catEntriesCount = catIndex;
            }
            
        } while (status == noErr);
	
	FSCloseIterator(dirIterator);
	
	for (i=0; i<catEntriesCount; i++) {
	    sortedCatalogEntries[i] = &catalogEntries[i];
	}
	
	return YES;
    }
    
    NSLog(@"Error opening FSIterator: %d", status);
    
    return NO;
}

- (BOOL)modifyNoteIfNecessary:(NoteObject*)aNoteObject usingCatalogEntry:(NoteCatalogEntry*)catEntry {
	//check dates
	UTCDateTime lastReadDate = fileModifiedDateOfNote(aNoteObject);
	UTCDateTime fileModDate = catEntry->lastModified;
	
	//should we always update the note's stored inode here regardless?
	
	if (lastReadDate.lowSeconds != fileModDate.lowSeconds ||
		lastReadDate.highSeconds != fileModDate.highSeconds ||
		lastReadDate.fraction != fileModDate.fraction) {
		//assume the file on disk was modified by someone other than us
		
		//figure out whether there is a conflict; is this file on disk older than the one that we have in memory? do we merge?
		//if ((UInt64*)&fileModDate > (UInt64*)&lastReadDate)

		//check if this note has changes in memory that still need to be committed -- that we _know_ the other writer never had a chance to see
		if (![unwrittenNotes containsObject:aNoteObject]) {

			if (![aNoteObject updateFromCatalogEntry:catEntry]) {
				NSLog(@"file %@ was modified but could not be updated", catEntry->filename);
				//return NO;
			}
			//do not call makeNoteDirty because use of the WAL in this instance would cause redundant disk activity
			//in the event of a crash this change could still be recovered; 
			
			[aNoteObject registerModificationWithOwnedServices];
			[self schedulePushToAllSyncServicesForNote:aNoteObject];
			
			[self note:aNoteObject attributeChanged:NotePreviewString]; //reverse delegate?
			
			[delegate contentsUpdatedForNote:aNoteObject];
			
			[self performSelector:@selector(scheduleUpdateListForAttribute:) withObject:NoteDateModifiedColumnString afterDelay:0.0];
			
			notesChanged = YES;
			NSLog(@"FILE WAS MODIFIED: %@", catEntry->filename);

			return YES;
		} else {
			//it's a conflict! we win.
			NSLog(@"%@ was modified with unsaved changes in NV! Deciding the conflict in favor of NV.", catEntry->filename); 
		}

	}
	
	return NO;
}

- (void)makeNotesMatchCatalogEntries:(NoteCatalogEntry**)catEntriesPtrs ofSize:(size_t)catCount {
    
    unsigned int aSize = [allNotes count];
    unsigned int bSize = catCount;
    
	ResizeBuffer((void***)&allNotesBuffer, aSize, &allNotesBufferSize);
	
	assert(allNotesBuffer != NULL);
	
    NoteObject **currentNotes = allNotesBuffer;
    [allNotes getObjects:(id*)currentNotes];
	
	mergesort((void *)allNotesBuffer, (size_t)aSize, sizeof(id), (int (*)(const void *, const void *))compareFilename);
	mergesort((void *)catEntriesPtrs, (size_t)bSize, sizeof(NoteCatalogEntry*), (int (*)(const void *, const void *))compareCatalogEntryName);
	    
    NSMutableArray *addedEntries = [NSMutableArray arrayWithCapacity:5];
    NSMutableArray *removedEntries = [NSMutableArray arrayWithCapacity:5];
	
    //oldItems(a,i) = currentNotes
    //newItems(b,j) = catEntries;
    
    unsigned int i, j, lastInserted = 0;
    
    for (i=0; i<aSize; i++) {
	
	BOOL exitedEarly = NO;
	for (j=lastInserted; j<bSize; j++) {
	    
	    CFComparisonResult order = CFStringCompare((CFStringRef)(catEntriesPtrs[j]->filename),
												   (CFStringRef)filenameOfNote(currentNotes[i]), 
												   kCFCompareCaseInsensitive);
	    if (order == kCFCompareGreaterThan) {    //if (A[i] < B[j])
		lastInserted = j;
		exitedEarly = YES;

		//NSLog(@"FILE DELETED (during): %@", filenameOfNote(currentNotes[i]));
		[removedEntries addObject:currentNotes[i]];
		break;
	    } else if (order == kCFCompareEqualTo) {			//if (A[i] == B[j])
							//the name matches, so add this to changed iff its contents also changed
		lastInserted = j + 1;
		exitedEarly = YES;
	    
		[self modifyNoteIfNecessary:currentNotes[i] usingCatalogEntry:catEntriesPtrs[j]];
		
		break;
	    }
	    
	    //NSLog(@"FILE ADDED (during): %@", catEntriesPtrs[j]->filename);
	    if ([notationPrefs catalogEntryAllowed:catEntriesPtrs[j]])
		[addedEntries addObject:[NSValue valueWithPointer:catEntriesPtrs[j]]];
	}
	
	if (!exitedEarly) {

	    //element A[i] "appended" to the end of list B
	    if (CFStringCompare((CFStringRef)filenameOfNote(currentNotes[i]),
				(CFStringRef)(catEntriesPtrs[MIN(lastInserted, bSize-1)]->filename), 
				kCFCompareCaseInsensitive) == kCFCompareGreaterThan) {
		lastInserted = bSize;
		
		//NSLog(@"FILE DELETED (after): %@", filenameOfNote(currentNotes[i]));
		[removedEntries addObject:currentNotes[i]];
	    }
	}
	
    }
    
    for (j=lastInserted; j<bSize; j++) {

	//NSLog(@"FILE ADDED (after): %@", catEntriesPtrs[j]->filename);
	if ([notationPrefs catalogEntryAllowed:catEntriesPtrs[j]])
	    [addedEntries addObject:[NSValue valueWithPointer:catEntriesPtrs[j]]];
    }
    
	if ([addedEntries count] && [removedEntries count]) {
		[self processNotesAdded:addedEntries removed:removedEntries];
	} else {
		
		if (![removedEntries count]) {
			for (i=0; i<[addedEntries count]; i++) {
				[self addNoteFromCatalogEntry:(NoteCatalogEntry*)[[addedEntries objectAtIndex:i] pointerValue]];
			}
		}
		
		if (![addedEntries count]) {			
			[[DeletionManager sharedManager] addDeletedNotes:removedEntries];
		}
	}

}

//find renamed notes through unique file IDs
//TODO: reconcile the "actually" added/deleted files into renames for files with identical content (sort by size)
- (void)processNotesAdded:(NSMutableArray*)addedEntries removed:(NSMutableArray*)removedEntries {
	unsigned int aSize = [removedEntries count], bSize = [addedEntries count];
    
    //sort on nodeID here
	[addedEntries sortUnstableUsingFunction:compareCatalogValueNodeID];
	[removedEntries sortUnstableUsingFunction:compareNodeID];
	
    //oldItems(a,i) = currentNotes
    //newItems(b,j) = catEntries;
    
    unsigned int i, j, lastInserted = 0;
    
    for (i=0; i<aSize; i++) {
		NoteObject *currentNote = [removedEntries objectAtIndex:i];
		
		BOOL exitedEarly = NO;
		for (j=lastInserted; j<bSize; j++) {
			
			NoteCatalogEntry *catEntry = (NoteCatalogEntry *)[[addedEntries objectAtIndex:j] pointerValue];
			int order = catEntry->nodeID - fileNodeIDOfNote(currentNote);
			
			if (order > 0) {    //if (A[i] < B[j])
				lastInserted = j;
				exitedEarly = YES;
				
				NSLog(@"File _actually_ deleted: %@", filenameOfNote(currentNote));
				[[DeletionManager sharedManager] addDeletedNote:currentNote];
				
				break;
			} else if (order == 0) {			//if (A[i] == B[j])
				lastInserted = j + 1;
				exitedEarly = YES;
				
				
				//note was renamed!
				NSLog(@"File %@ was renamed to %@", filenameOfNote(currentNote), catEntry->filename);
				if (![self modifyNoteIfNecessary:currentNote usingCatalogEntry:catEntry]) {
					//at least update the file name, because we _know_ that changed
					
					directoryChangesFound = YES;

					[currentNote setFilename:(NSString*)catEntry->filename withExternalTrigger:YES];
				}
				
				notesChanged = YES;
				
				break;
			}
			
			//a new file was found on the disk! read it into memory!
			
			NSLog(@"File _actually_ added: %@", catEntry->filename);
			[self addNoteFromCatalogEntry:catEntry];
		}
		
		if (!exitedEarly) {
			
			//element A[i] "appended" to the end of list B
			
			NoteCatalogEntry *appendedCatEntry = (NoteCatalogEntry *)[[addedEntries objectAtIndex:MIN(lastInserted, bSize-1)] pointerValue];
			if (fileNodeIDOfNote(currentNote) - appendedCatEntry->nodeID > 0) {
				lastInserted = bSize;
				
				//file deleted from disk; 
				NSLog(@"File _actually_ deleted: %@", filenameOfNote(currentNote));
				[[DeletionManager sharedManager] addDeletedNote:currentNote];
			}
		}
    }
    
    for (j=lastInserted; j<bSize; j++) {
		NoteCatalogEntry *appendedCatEntry = (NoteCatalogEntry *)[[addedEntries objectAtIndex:j] pointerValue];
		NSLog(@"File _actually_ added: %@", appendedCatEntry->filename);
		[self addNoteFromCatalogEntry:appendedCatEntry];
    }
}

- (void)noteDidNotWrite:(NoteObject*)note errorCode:(OSStatus)error {
    [unwrittenNotes addObject:note];
    
    if (error != lastWriteError) {
		NSRunAlertPanel([NSString stringWithFormat:NSLocalizedString(@"Changed notes could not be saved because %@.",
																	 @"alert title appearing when notes couldn't be written"), 
			[NSString reasonStringFromCarbonFSError:error]], @"", NSLocalizedString(@"OK",nil), NULL, NULL);
		
		lastWriteError = error;
    }
}

- (void)synchronizeNoteChanges:(NSTimer*)timer {
    
    if ([unwrittenNotes count] > 0) {
		lastWriteError = noErr;
		if ([notationPrefs notesStorageFormat] != SingleDatabaseFormat) {
			[unwrittenNotes makeObjectsPerformSelector:@selector(writeUsingCurrentFileFormatIfNecessary)];
			
			//this always seems to call ourselves
			FNNotify(&noteDirectoryRef, kFNDirectoryModifiedMessage, kFNNoImplicitAllSubscription);
		}
		if (walWriter) {
			//append unwrittenNotes to journal, if one exists
			[unwrittenNotes makeObjectsPerformSelector:@selector(writeUsingJournal:) withObject:walWriter];
		}
				
		//NSLog(@"wrote %d unwritten notes", [unwrittenNotes count]);
		
		[unwrittenNotes removeAllObjects];
		
		[self scheduleUpdateListForAttribute:NoteDateModifiedColumnString];

    }
    
    if (changeWritingTimer) {
		[changeWritingTimer invalidate];
		[changeWritingTimer release];
		changeWritingTimer = nil;
    }
}

- (NSData*)aliasDataForNoteDirectory {
    NSData* theData = nil;
    
    FSRef userHomeFoundRef, *relativeRef = &userHomeFoundRef;
    
    if (aliasNeedsUpdating) {
		OSErr err = FSFindFolder(kUserDomain, kCurrentUserFolderType, kCreateFolder, &userHomeFoundRef);
		if (err != noErr) {
			relativeRef = NULL;
			NSLog(@"FSFindFolder error: %d", err);
		}
    }
	
    //re-fill handle from fsref if necessary, storing path relative to user directory
    if (aliasNeedsUpdating && FSNewAlias(relativeRef, &noteDirectoryRef, &aliasHandle ) != noErr)
		return nil;
	
    if (aliasHandle != NULL) {
		aliasNeedsUpdating = NO;
		
		HLock((Handle)aliasHandle);
		theData = [NSData dataWithBytes:*aliasHandle length:GetHandleSize((Handle) aliasHandle)];
		HUnlock((Handle)aliasHandle);
	    
		return theData;
    }
    
    return nil;
}

- (void)setAliasNeedsUpdating:(BOOL)needsUpdate {
	aliasNeedsUpdating = needsUpdate;
}

- (BOOL)aliasNeedsUpdating {
	return aliasNeedsUpdating;
}

- (void)checkIfNotationIsTrashed {
	if ([self notesDirectoryIsTrashed]) {
		
		NSString *trashLocation = [[NSString pathWithFSRef:&noteDirectoryRef] stringByAbbreviatingWithTildeInPath];
		if (!trashLocation) trashLocation = @"unknown";
		int result = NSRunCriticalAlertPanel([NSString stringWithFormat:NSLocalizedString(@"Your notes directory (%@) appears to be in the Trash.",nil), trashLocation], 
											 NSLocalizedString(@"If you empty the Trash now, you could lose your notes. Relocate the notes to a less volatile folder?",nil),
											 NSLocalizedString(@"Relocate Notes",nil), NSLocalizedString(@"Quit",nil), NULL);
		if (result == NSAlertDefaultReturn)
			[self relocateNotesDirectory];
		else [NSApp terminate:nil];
	}
}

- (void)trashRemainingNoteFilesInDirectory {
	NSAssert([notationPrefs notesStorageFormat] == SingleDatabaseFormat, @"We shouldn't be removing files if the storage is not single-database");	
	[allNotes makeObjectsPerformSelector:@selector(moveFileToTrash)];
	[self notifyOfChangedTrash];
}

- (void)updateLinksToNote:(NoteObject*)aNoteObject fromOldName:(NSString*)oldname {
    //O(n)
}

//for making notes that we don't already own
- (NoteObject*)addNote:(NSAttributedString*)attributedContents withTitle:(NSString*)title {
    if (!title || ![title length])
		title = NSLocalizedString(@"Untitled Note", @"Title of a nameless note");
    
    if (!attributedContents)
		attributedContents = [[[NSAttributedString alloc] initWithString:@"" attributes:[prefsController noteBodyAttributes]] autorelease];
    
    NoteObject *note = [[NoteObject alloc] initWithNoteBody:attributedContents title:title
											 uniqueFilename:[self uniqueFilenameForTitle:title fromNote:nil]
													 format:[self currentNoteStorageFormat]];
    
    [self addNewNote:note];
    
    //we are the the owner of this note
    [note release];
    
    return note;
}

- (void)addNewNote:(NoteObject*)note {
    [self _addNote:note];
	
	//clear aNoteObject's syncServicesMD to facilitate sync recreation upon undoing of deletion
	//new notes should not have any sync MD; if they do, they should be added using -addNotesFromSync:
	//problem is that note could very likely still be in the process of syncing, in which case these dicts will be accessed
	//for simplenote is is necessary only once the iPhone app has fully deleted the note off the server; otherwise a regular update will recreate it
	//[note removeAllSyncServiceMD];
    
	[note makeNoteDirtyUpdateTime:YES updateFile:YES];
	//force immediate update
	[self synchronizeNoteChanges:nil];
	
	if ([[self undoManager] isUndoing]) {
		//prohibit undoing of creation--only redoing of deletion
		//NSLog(@"registering %s", _cmd);
		[undoManager registerUndoWithTarget:self selector:@selector(removeNote:) object:note];
		if (! [[self undoManager] isUndoing] && ! [[self undoManager] isRedoing])
			[undoManager setActionName:[NSString stringWithFormat:NSLocalizedString(@"Create Note quotemark%@quotemark",@"undo action name for creating a single note"), titleOfNote(note)]];
	}
    
	[self resortAllNotes];
    [self refilterNotes];
    
    [delegate notation:self revealNote:note options:NVEditNoteToReveal | NVOrderFrontWindow];
}

//do not update the view here (why not?)
- (NoteObject*)addNoteFromCatalogEntry:(NoteCatalogEntry*)catEntry {
	NoteObject *newNote = [[NoteObject alloc] initWithCatalogEntry:catEntry delegate:self];
	[self _addNote:newNote];
	[newNote release];
	
	[self schedulePushToAllSyncServicesForNote:newNote];
	
	directoryChangesFound = YES;
	
	return newNote;
}

- (void)addNotesFromSync:(NSArray*)noteArray {
	
	if (![noteArray count]) return; 
	
	unsigned int i;
	
	if ([[self undoManager] isUndoing]) [undoManager beginUndoGrouping];
	for (i=0; i<[noteArray count]; i++) {
		NoteObject * note = [noteArray objectAtIndex:i];
		
		[self _addNote:note];
		
		[note makeNoteDirtyUpdateTime:NO updateFile:YES];
		
		//absolutely ensure that this note is pushed to the rest of the services
		[note registerModificationWithOwnedServices];
		[self schedulePushToAllSyncServicesForNote:note];
	}
	if ([[self undoManager] isUndoing]) [undoManager endUndoGrouping];
	//don't need to reverse-register undo because removeNote/s: will never use this method
	
	[self synchronizeNoteChanges:nil];
		
	[self resortAllNotes];
	[self refilterNotes];	
}

- (void)addNotes:(NSArray*)noteArray {
	
	if (![noteArray count]) return; 
	
	unsigned int i;
	
	if ([[self undoManager] isUndoing]) [undoManager beginUndoGrouping];
	for (i=0; i<[noteArray count]; i++) {
		NoteObject * note = [noteArray objectAtIndex:i];
		
		[self _addNote:note];
		
		[note makeNoteDirtyUpdateTime:YES updateFile:YES];
	}
	if ([[self undoManager] isUndoing]) [undoManager endUndoGrouping];
	
	[self synchronizeNoteChanges:nil];
	
	if ([[self undoManager] isUndoing]) {
		//prohibit undoing of creation--only redoing of deletion
		//NSLog(@"registering %s", _cmd);
		[undoManager registerUndoWithTarget:self selector:@selector(removeNotes:) object:noteArray];		
		if (! [[self undoManager] isUndoing] && ! [[self undoManager] isRedoing])
			[undoManager setActionName:[NSString stringWithFormat:NSLocalizedString(@"Add %d Notes", @"undo action name for creating multiple notes"), [noteArray count]]];	
	}
	[self resortAllNotes];
	[self refilterNotes];
	
	if ([noteArray count] > 1)
		[delegate notation:self revealNotes:noteArray];
	else
		[delegate notation:self revealNote:[noteArray lastObject] options:NVOrderFrontWindow];
}

- (void)note:(NoteObject*)note attributeChanged:(NSString*)attribute {
	
	if ([attribute isEqualToString:NotePreviewString]) {
		if ([prefsController tableColumnsShowPreview]) {
			NSUInteger idx = [notesListDataSource indexOfObjectIdenticalTo:note];
			if (NSNotFound != idx) {
				[delegate rowShouldUpdate:idx];
			}
		}
		//this attribute is not displayed as a column
		return;
	}
	
	//[self scheduleUpdateListForAttribute:attribute];
	[self performSelector:@selector(scheduleUpdateListForAttribute:) withObject:attribute afterDelay:0.0];

	//special case for title requires this method, as app controller needs to know a few note-specific things
	if ([attribute isEqualToString:NoteTitleColumnString])
		[delegate titleUpdatedForNote:note];
}

- (void)scheduleUpdateListForAttribute:(NSString*)attribute {
	
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(scheduleUpdateListForAttribute:) object:attribute];
	
	if ([[sortColumn identifier] isEqualToString:attribute]) {
		
		if ([delegate notationListShouldChange:self]) {
			[self sortAndRedisplayNotes];
		} else {
			[self performSelector:@selector(scheduleUpdateListForAttribute:) withObject:attribute afterDelay:1.5];
		}
	} else {
		//catch col updates even if they aren't the sort key
		
		NSEnumerator *enumerator = [[prefsController visibleTableColumns] objectEnumerator];
		NSString *colIdentifier = nil;
		
		//check to see if appropriate col is visible
		while ((colIdentifier = [enumerator nextObject])) {
			if ([colIdentifier isEqualToString:attribute]) {
				if ([delegate notationListShouldChange:self]) {
					[delegate notationListMightChange:self];
					[delegate notationListDidChange:self];
				} else {
					[self performSelector:@selector(scheduleUpdateListForAttribute:) withObject:attribute afterDelay:1.5];
				}
				break;
			}
		}
	}
}

- (void)scheduleWriteForNote:(NoteObject*)note {

	BOOL immediately = NO;
	notesChanged = YES;
	
	[unwrittenNotes addObject:note];
	
	//always synchronize absolutely no matter what 15 seconds after any change
	if (!changeWritingTimer)
	    changeWritingTimer = [[NSTimer scheduledTimerWithTimeInterval:(immediately ? 0.0 : 15.0) target:self 
								 selector:@selector(synchronizeNoteChanges:)
								 userInfo:nil repeats:NO] retain];
	
	//next user change always invalidates queued write from performSelector, but not queued write from timer
	//this avoids excessive writing and any potential and unnecessary disk access while user types
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(synchronizeNoteChanges:) object:nil];
	
	if (walWriter) {
		//perhaps a more general user interface activity timer would be better for this? update process syncs every 30 secs, anyway...
		[NSObject cancelPreviousPerformRequestsWithTarget:walWriter selector:@selector(synchronize) object:nil];
		//fsyncing WAL to disk can cause noticeable interruption when run from main thread
		[walWriter performSelector:@selector(synchronize) withObject:nil afterDelay:15.0];
	}
	
	if (!immediately) {
		//timer is already scheduled if immediately is true
		//queue to write 2.7 seconds after last user change; 
		[self performSelector:@selector(synchronizeNoteChanges:) withObject:nil afterDelay:2.7];
	}
}

//the gatekeepers!
- (void)_addNote:(NoteObject*)aNoteObject {
    [aNoteObject setDelegate:self];	
	
    [allNotes addObject:aNoteObject];
	[deletedNotes removeObject:aNoteObject];
    
    notesChanged = YES;
}

//the gateway methods must always show warnings, or else flash overlay window if show-warnings-pref is off
- (void)removeNotes:(NSArray*)noteArray {
	NSEnumerator *enumerator = [noteArray objectEnumerator];
	NoteObject* note;
	
	[undoManager beginUndoGrouping];
	while ((note = [enumerator nextObject])) {
		[self removeNote:note];
	}
	[undoManager endUndoGrouping];
	if (! [[self undoManager] isUndoing] && ! [[self undoManager] isRedoing])
		[undoManager setActionName:[NSString stringWithFormat:NSLocalizedString(@"Delete %d Notes",@"undo action name for deleting notes"), [noteArray count]]];
	
}

- (void)removeNote:(NoteObject*)aNoteObject {
    //reset linking labels and their notes
    
	[aNoteObject retain];
    [allNotes removeObjectIdenticalTo:aNoteObject];
	DeletedNoteObject *deletedNote = [self _addDeletedNote:aNoteObject];
    
    notesChanged = YES;
	
	//force-write any cached note changes to make sure that their LSNs are smaller than this deleted note's LSN
	[self synchronizeNoteChanges:nil];
    
    //we do this after removing it from the array to avoid re-discovering a removed file
    if ([notationPrefs notesStorageFormat] != SingleDatabaseFormat) {
		[aNoteObject removeFileFromDirectory];
    }
	//add journal removal event
	if (walWriter && ![walWriter writeRemovalForNote:aNoteObject]) {
		NSLog(@"Couldn't log note removal");
	}
	
	//a removal command will be sent to sync services if aNoteObject contains a matching syncServicesMD dict 
	//(e.g., already been synced at least once)
	//make sure we use the same deleted note that was added to the list of deleted notes, to simplify record-keeping
	//if the note didn't have metadata, try to sync it anyway so that the service knows this note shouldn't be created
	[self schedulePushToAllSyncServicesForNote: deletedNote ? deletedNote : [DeletedNoteObject deletedNoteWithNote:aNoteObject]];
    
	[self _registerDeletionUndoForNote:aNoteObject];
		
	//delete note from bookmarks, too
	[[prefsController bookmarksController] removeBookmarkForNote:aNoteObject];
    
    [aNoteObject release];
    
    [self refilterNotes];
}

- (void)_purgeAlreadyDistributedDeletedNotes {
	//purge deletedNotes of objects without any more syncMD entries;
	//once a note has been deleted from all services, there's no need to keep it around anymore

	NSUInteger i = 0;
	NSArray *dnArray = [deletedNotes allObjects];
	for (i = 0; i<[dnArray count]; i++) {
		DeletedNoteObject *dnObj = [dnArray objectAtIndex:i];
		if (![[dnObj syncServicesMD] count]) {
			[deletedNotes removeObject:dnObj];
			notesChanged = YES;
		}
	}
	//NSLog(@"%s: deleted notes left: %@", _cmd, deletedNotes);
}

- (DeletedNoteObject*)_addDeletedNote:(id<SynchronizedNote>)aNote {
	//currently coupled to -[allNotes removeObjectIdenticalTo:]
	//don't need to remember this deleted note unless it was already synced with some service
	//furthermore, after that deleted note has been remotely-removed from all services with which it was previously synced,
	//can it be purged from this database once and for all?
	//e.g., each successful syncservice deletion would also remove that service's entry from syncServicesMD
	//when syncServicesMD was empty, it would be removed from the set
	//but what about synchronization systems without explicit delete APIs?
	
	if ([[aNote syncServicesMD] count]) {
		//it is important to use the actual deleted note if one is passed
		DeletedNoteObject *deletedNote = [aNote isKindOfClass:[DeletedNoteObject class]] ? aNote : [DeletedNoteObject deletedNoteWithNote:aNote];
		[deletedNotes addObject:deletedNote];
		return deletedNote;
	}
	return nil;
}

- (void)removeSyncMDFromDeletedNotesInSet:(NSSet*)notesToOrphan forService:(NSString*)serviceName {
	NSMutableSet *matchingNotes = [deletedNotes setIntersectedWithSet:notesToOrphan];
	[matchingNotes makeObjectsPerformSelector:@selector(removeAllSyncMDForService:) withObject:serviceName];
}

- (void)_registerDeletionUndoForNote:(NoteObject*)aNote {	
	[undoManager registerUndoWithTarget:self selector:@selector(addNewNote:) object:aNote];			
	if (![undoManager isUndoing] && ![undoManager isRedoing])
		[undoManager setActionName:[NSString stringWithFormat:NSLocalizedString(@"Delete quotemark%@quotemark",@"undo action name for deleting a single note"), titleOfNote(aNote)]];				
}			


- (void)setUndoManager:(NSUndoManager*)anUndoManager {
    [undoManager autorelease];
    undoManager = [anUndoManager retain];
}

- (NSUndoManager*)undoManager {
    return undoManager;
}

- (void)updateDateStringsIfNecessary {
	
	unsigned int currentHours = hoursFromAbsoluteTime(CFAbsoluteTimeGetCurrent());
	
	if (currentHours != lastCheckedDateInHours) {
		lastCheckedDateInHours = currentHours;
		
		[delegate notationListMightChange:self];
		resetCurrentDayTime();
		[allNotes makeObjectsPerformSelector:@selector(updateDateStrings)];
		[delegate notationListDidChange:self];
	}
}

- (void)restyleAllNotes {
	NSFont *baseFont = [notationPrefs baseBodyFont];
	NSAssert(baseFont != nil, @"base body font from notation prefs should ALWAYS be valid!");
	
	[allNotes makeObjectsPerformSelector:@selector(updateUnstyledTextWithBaseFont:) withObject:baseFont];
	
	[notationPrefs setBaseBodyFont:[prefsController noteBodyFont]];
}

//used by BookmarksController

- (NoteObject*)noteForUUIDBytes:(CFUUIDBytes*)bytes {
	NSUInteger noteIndex = [allNotes indexOfNoteWithUUIDBytes:bytes];
	if (noteIndex != NSNotFound) return [allNotes objectAtIndex:noteIndex];
	return nil;	
}

//re-searching for all notes each time a label is added or removed is unnecessary, I think
- (void)note:(NoteObject*)note didAddLabelSet:(NSSet*)labelSet {
	[labelsListController addLabelSet:labelSet toNote:note];
        
    //this can only happen while the note is visible
	
	//[self refilterNotes];
}

- (void)note:(NoteObject*)note didRemoveLabelSet:(NSSet*)labelSet {
	[labelsListController removeLabelSet:labelSet fromNote:note];
        
	//[self refilterNotes];
}

- (void)filterNotesFromLabelAtIndex:(int)labelIndex {
	NSArray *notes = [[labelsListController notesAtFilteredIndex:labelIndex] allObjects];
	
	[delegate notationListMightChange:self];
	[notesListDataSource fillArrayFromArray:notes];
	
	[delegate notationListDidChange:self];	
}

- (void)filterNotesFromLabelIndexSet:(NSIndexSet*)indexSet {
	NSArray *notes = [[labelsListController notesAtFilteredIndexes:indexSet] allObjects];
	
	[delegate notationListMightChange:self];
	[notesListDataSource fillArrayFromArray:notes];
	
	[delegate notationListDidChange:self];
}

- (BOOL)filterNotesFromString:(NSString*)string {
	
	[delegate notationListMightChange:self];
	if ([self filterNotesFromUTF8String:[string lowercaseUTF8String] forceUncached:NO]) {
		[delegate notationListDidChange:self];
		
		return YES;
	}
	
	return NO;
}

- (void)refilterNotes {
	
    [delegate notationListMightChange:self];
    [self filterNotesFromUTF8String:(currentFilterStr ? currentFilterStr : "") forceUncached:YES];
    [delegate notationListDidChange:self];
}

- (BOOL)filterNotesFromUTF8String:(const char*)searchString forceUncached:(BOOL)forceUncached {
    BOOL stringHasExistingPrefix = YES;
    BOOL didFilterNotes = NO;
    size_t oldLen = 0, newLen = 0;
	NSUInteger i, initialCount = [notesListDataSource count];
    
	NSAssert(searchString != NULL, @"filterNotesFromUTF8String requires a non-NULL argument");
	
	newLen = strlen(searchString);
    
	//PHASE 1: determine whether notes can be searched from where they are--if not, start on all the notes
    if (!currentFilterStr || forceUncached || ((oldLen = strlen(currentFilterStr)) > newLen) ||
		strncmp(currentFilterStr, searchString, oldLen)) {
		
		//the search must be re-initialized; our strings don't have the same prefix
		
		[notesListDataSource fillArrayFromArray:allNotes];
		//[labelsListController unfilterLabels];
		
		stringHasExistingPrefix = NO;
		lastWordInFilterStr = 0;
		didFilterNotes = YES;
		
		//		NSLog(@"filter: scanning all notes");
    }
    
	
	//PHASE 2: actually search for notes
	NoteFilterContext filterContext;
	
	//if there is a quote character in the string, use that as a delimiter, as we will search by phrase
	//perhaps we could add some additional delimiters like punctuation marks here
    char *token, *separators = (strchr(searchString, '"') ? "\"" : " :\t\r\n");
    manglingString = replaceString(manglingString, searchString);
    
    BOOL touchedNotes = NO;
    
    if (!didFilterNotes || newLen > 0) {
		//only bother searching each note if we're actually searching for something
		//otherwise, filtered notes already reflect all-notes-state
		
		char *preMangler = manglingString + lastWordInFilterStr;
		while ((token = strsep(&preMangler, separators))) {
			
			if (*token != '\0') {
				//if this is the same token that we had scanned previously
				filterContext.useCachedPositions = stringHasExistingPrefix && (token == manglingString + lastWordInFilterStr);
				filterContext.needle = token;
				
				touchedNotes = YES;
				
				if ([notesListDataSource filterArrayUsingFunction:(BOOL (*)(id, void*))noteContainsUTF8String context:&filterContext])
					didFilterNotes = YES;
								
				lastWordInFilterStr = token - manglingString;
			}
		}
    }
    
	//PHASE 3: reset found pointers in case have been cleared
	NSUInteger filteredNoteCount = [notesListDataSource count];
	NoteObject **notesBuffer = [notesListDataSource immutableObjects];
	
    if (didFilterNotes) {
		
		if (!touchedNotes) {
			//I can't think of any situation where notes were filtered and not touched--EXCEPT WHEN REMOVING A NOTE (>= vs. ==)
			assert(filteredNoteCount >= [allNotes count]);
			
			//reset found-ptr values; the search string was effectively blank and so no notes were examined
			for (i=0; i<filteredNoteCount; i++)
				resetFoundPtrsForNote(notesBuffer[i]);
		}
		
		//we have to re-create the array at each iteration while searching notes, but not here, so we can wait until the end
		//[labelsListController recomputeListFromFilteredSet];
    }
    
	//PHASE 4: autocomplete based on results
	//even if the controller didn't filter, the search string could have changed its representation wrt spacing
	//which will still influence note title prefixes 
	selectedNoteIndex = NSNotFound;
	
    if (newLen && [prefsController autoCompleteSearches]) {
		//TODO: this should match the note with the shortest title first
		for (i=0; i<filteredNoteCount; i++) {			
			//because we already searched word-by-word up there, this is just way simpler
			if (noteTitleHasPrefixOfUTF8String(notesBuffer[i], searchString, newLen)) {
				selectedNoteIndex = i;
				break;
			}
		}
    }
    
    currentFilterStr = replaceString(currentFilterStr, searchString);
	
	if (!initialCount && initialCount == filteredNoteCount)
		return NO;
    
    return didFilterNotes;
}

- (NSUInteger)preferredSelectedNoteIndex {
    return selectedNoteIndex;
}
- (BOOL)preferredSelectedNoteMatchesSearchString {
	NoteObject *obj = [self noteObjectAtFilteredIndex:selectedNoteIndex];
	if (obj) return noteTitleMatchesUTF8String(obj, currentFilterStr);
	return NO;
}

- (NoteObject*)noteObjectAtFilteredIndex:(int)noteIndex {
	unsigned int theIndex = (unsigned int)noteIndex;
	
	if (theIndex < [notesListDataSource count])
		return [notesListDataSource immutableObjects][theIndex];
	
	return nil;
}

- (NSArray*)notesAtIndexes:(NSIndexSet*)indexSet {
	return [notesListDataSource objectsAtFilteredIndexes:indexSet];
}

//O(n^2) at best, but at least we're dealing with C arrays

- (NSIndexSet*)indexesOfNotes:(NSArray*)noteArray {
	NSMutableIndexSet *noteIndexes = [[NSMutableIndexSet alloc] init];
	
	NSUInteger i, noteCount = [noteArray count];
	
	id *notes = (id*)malloc(noteCount * sizeof(id));
	[noteArray getObjects:notes];
	
	for (i=0; i<noteCount; i++) {
		NSUInteger noteIndex = [notesListDataSource indexOfObjectIdenticalTo:notes[i]];
		
		if (noteIndex != NSNotFound)
			[noteIndexes addIndex:noteIndex];
	}
	
	free(notes);
	
	return [noteIndexes autorelease];
}

- (NSUInteger)indexInFilteredListForNoteIdenticalTo:(NoteObject*)note {
	return [notesListDataSource indexOfObjectIdenticalTo:note];
}

- (NSUInteger)totalNoteCount {
	return [allNotes count];
}

- (NoteAttributeColumn*)sortColumn {
	return sortColumn;
}

- (void)setSortColumn:(NoteAttributeColumn*)col { 
	
    [sortColumn release];
	sortColumn = [col retain];
	
	[self sortAndRedisplayNotes];
}

//re-sort without refiltering, to avoid removing notes currently being edited
- (void)sortAndRedisplayNotes {
	
	[delegate notationListMightChange:self];

	NoteAttributeColumn *col = sortColumn;
	if (col) {
		BOOL reversed = [prefsController tableIsReverseSorted];
		NSInteger (*sortFunction) (id *, id *) = (reversed ? [col reverseSortFunction] : [col sortFunction]);
		NSInteger (*stringSortFunction) (id*, id*) = (reversed ? compareTitleStringReverse : compareTitleString);
		
		[allNotes sortStableUsingFunction:stringSortFunction usingBuffer:&allNotesBuffer ofSize:&allNotesBufferSize];
		if (sortFunction != stringSortFunction)
			[allNotes sortStableUsingFunction:sortFunction usingBuffer:&allNotesBuffer ofSize:&allNotesBufferSize];
		
		
		if ([notesListDataSource count] != [allNotes count]) {
				
			[notesListDataSource sortStableUsingFunction:stringSortFunction];	
		    if (sortFunction != stringSortFunction)
				[notesListDataSource sortStableUsingFunction:sortFunction];
			
		} else {
		    //mirror from allNotes; notesListDataSource is not filtered
		    [notesListDataSource fillArrayFromArray:allNotes];
		}
		
		[delegate notationListDidChange:self];
	}
}

- (void)resortAllNotes {
	
	NoteAttributeColumn *col = sortColumn;
	
	if (col) {
		BOOL reversed = [prefsController tableIsReverseSorted];
	
		NSInteger (*sortFunction) (id*, id*) = (reversed ? [col reverseSortFunction] : [col sortFunction]);
		NSInteger (*stringSortFunction) (id*, id*) = (reversed ? compareTitleStringReverse : compareTitleString);

		[allNotes sortStableUsingFunction:stringSortFunction usingBuffer:&allNotesBuffer ofSize:&allNotesBufferSize];
		if (sortFunction != stringSortFunction)
			[allNotes sortStableUsingFunction:sortFunction usingBuffer:&allNotesBuffer ofSize:&allNotesBufferSize];
	}
}

- (float)titleColumnWidth {
	return titleColumnWidth;
}

- (void)regeneratePreviewsForColumn:(NSTableColumn*)col visibleFilteredRows:(NSRange)rows forceUpdate:(BOOL)force {
	
	float width = [col width] - [NSScroller scrollerWidthForControlSize:NSRegularControlSize];
	
	if (force || roundf(width) != roundf(titleColumnWidth)) {
		titleColumnWidth = width;
		
		//regenerate previews for visible rows immediately and post a delayed message to regenerate previews for all rows
		if (rows.length > 0) {
			CFArrayRef visibleNotes = CFArrayCreate(NULL, (const void **)([notesListDataSource immutableObjects] + rows.location), rows.length, NULL);
			[(NSArray*)visibleNotes makeObjectsPerformSelector:@selector(updateTablePreviewString)];
			CFRelease(visibleNotes);
		}
		
		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(regenerateAllPreviews) object:nil];
		[self performSelector:@selector(regenerateAllPreviews) withObject:nil afterDelay:0.0];
	}
}

- (void)regenerateAllPreviews {
	[allNotes makeObjectsPerformSelector:@selector(updateTablePreviewString)];
}

- (id)labelsListDataSource {
    return labelsListController;
}

- (id)notesListDataSource {
    return notesListDataSource;
}

- (SyncSessionController*)syncSessionController {
	return syncSessionController;
}

- (void)dealloc {
    
    DisposeFNSubscriptionUPP(subscriptionCallback);
	if (fsCatInfoArray)
		free(fsCatInfoArray);
	if (HFSUniNameArray)
		free(HFSUniNameArray);
    if (catalogEntries)
		free(catalogEntries);
    if (sortedCatalogEntries)
		free(sortedCatalogEntries);
    if (allNotesBuffer)
		free(allNotesBuffer);
	
    [undoManager release];
    [notesListDataSource release];
    [labelsListController release];
	[syncSessionController release];
    [allNotes release];
	[deletedNotes release];
	[notationPrefs release];
	[unwrittenNotes release];
    
    [super dealloc];
}

@end


