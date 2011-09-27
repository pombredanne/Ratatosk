/*
 * WLRemoteObject.j
 * RemoteObject
 *
 * Refactored from Models.j, created by Alexander Ljungberg on November 16, 2009.
 * Copyright 2009, WireLoad, LLC All rights reserved.
 */

var WLRemoteObjectByClassByPk = {},
    WLRemoteObjectDirtProof = NO;

/*!
    A WLRemoteObject has a primary key and is equal to another WLRemoteObject
    with the same class and Pk. The object supports loading and saving
    from and to JSON and keeps automatic track of which properties are
    dirty and need to be saved.

    By default, objects autosave when simple properties are changed.

    Subclasses must implement
    - (init)
    - (CPString)remotePath

*/
@implementation WLRemoteObject : CPObject
{
    long            pk @accessors;

    CPSet           _remoteProperties;
    Object          _propertyLastModified;
    CPSet           _deferredProperties;
    CPDate          lastSyncedAt @accessors;
    WLRemoteAction  createAction;
    WLRemoteAction  deleteAction;
    WLRemoteAction  saveAction;
    WLRemoteAction  contentDownloadAction;
    BOOL            _shouldAutoSave @accessors(property=shouldAutoSave);
    BOOL            _suppressAutoSave;
    BOOL            _suppressRemotePropertiesObservation;
    BOOL            _mustSaveAgain;
    id              _delegate @accessors(property=delegate);

    CPUndoManager   undoManager @accessors;
}

+ (id)instanceOf:clz forPk:(long)pk
{
    if (pk === nil)
        return nil;

    if (WLRemoteObjectByClassByPk === nil)
        WLRemoteObjectByClassByPk = {};

    if (WLRemoteObjectByClassByPk[clz] == undefined)
        WLRemoteObjectByClassByPk[clz] = {};

    if (WLRemoteObjectByClassByPk[clz][pk] == undefined)
        return nil;

    return WLRemoteObjectByClassByPk[clz][pk];
}

+ (void)setInstance:obj forPk:(long)pk
{
    if (pk === nil)
        return nil;

    if (WLRemoteObjectByClassByPk === nil)
        WLRemoteObjectByClassByPk = {};

    var clz = [obj class];
    if (WLRemoteObjectByClassByPk[clz] == undefined)
        WLRemoteObjectByClassByPk[clz] = {};

    WLRemoteObjectByClassByPk[clz][pk] = obj;
}

+ (void)clearInstanceCache
{
    WLRemoteObjectByClassByPk = {};
}

+ (void)setDirtProof:(BOOL)aFlag
{
    WLRemoteObjectDirtProof = aFlag;
}

+ (BOOL)isLoadingObjects
{
    // This is not the original purpose, but works out quite nicely.
    return WLRemoteObjectDirtProof;
}

- (void)init
{
    if (self = [super init])
    {
        _shouldAutoSave = YES;
        _remoteProperties = [CPSet set];
        _propertyLastModified = {};
        _deferredProperties = [CPSet set];
        lastSyncedAt = [CPDate distantPast];
        undoManager = nil;
        [self registerRemoteProperties:[
            [RemoteProperty propertyWithLocalName:'pk' remoteName:'id'],
        ]];
    }
    return self;
}

- (void)registerRemoteProperties:(CPArray)someProperties
{
    for (var i = 0, count = [someProperties count]; i < count; i++)
    {
        var property = someProperties[i];
        if ([_remoteProperties containsObject:property])
            continue;

        if (!_suppressRemotePropertiesObservation)
        {
            [self addObserver:self forKeyPath:[property localName] options:nil context:property];
            [self registerKeyForUndoManagement:[property localName]];
        }
        [_remoteProperties addObject:property];
        [_deferredProperties addObject:property];
    }
}

- (void)registerKeyForUndoManagement:(CPString)aLocalName
{
    if (aLocalName == "pk")
        return;
    [[self undoManager] observeChangesForKeyPath:aLocalName ofObject:self];
}

- (RemoteProperty)remotePropertyForKey:(CPString)aLocalName
{
    var remotePropertiesEnumerator = [_remoteProperties objectEnumerator],
        property;
    while (property = [remotePropertiesEnumerator nextObject])
        if ([property localName] == aLocalName)
            return property;
    return nil;
}

- (void)activateRemotePropertiesObservation
{
    var remotePropertiesEnumerator = [_remoteProperties objectEnumerator],
        property;
    while (property = [remotePropertiesEnumerator nextObject])
    {
        [self registerKeyForUndoManagement:[property localName]];
        [self addObserver:self forKeyPath:[property localName] options:nil context:property];
    }
}

- (void)observeValueForKeyPath:(CPString)aKeyPath ofObject:(id)anObject change:(CPDictionary)change context:(id)aContext
{
    var isBeforeFlag = !![change objectForKey:CPKeyValueChangeNotificationIsPriorKey];
    if (isBeforeFlag)
        return;

    if ([change valueForKey:CPKeyValueChangeKindKey] == CPKeyValueChangeSetting && [_remoteProperties containsObject:aContext])
    {
        var before = [change valueForKey:CPKeyValueChangeOldKey],
            after = [change valueForKey:CPKeyValueChangeNewKey];
        if (before !== after && ((before === nil && after !== nil) || ![before isEqual:after]))
            [self makeDirtyProperty:[aContext localName]];
        [_deferredProperties removeObject:aContext];
    }
}

- (void)cleanAll
{
    _propertyLastModified = {};
}

- (void)cleanProperty:(CPString)localName
{
    delete _propertyLastModified[localName];
}

- (void)makeAllDirty
{
    var remotePropertiesEnumerator = [_remoteProperties objectEnumerator],
        property;
    while (property = [remotePropertiesEnumerator nextObject])
    {
        [self makeDirtyProperty:[property localName]]
    }
}

- (void)makeDirtyProperty:(CPString)localName
{
    if (WLRemoteObjectDirtProof)
        return;

    _propertyLastModified[localName] = [CPDate date];
    if (!_suppressAutoSave && ![self isNew] && _shouldAutoSave)
    {
        // Run the check for whether we should autosave at the end of the
        // run loop so that batch changes can collate. This also enables
        // the [object setProperty:X];[object cleanAll]; without having to
        // suppress auto saves.
        [[CPRunLoop currentRunLoop] performSelector:"ensureSaved" target:self argument:nil order:0 modes:[CPDefaultRunLoopMode]];
    }
}

- (BOOL)isDirty
{
    return [[self dirtyProperties] count] > 0;
}

- (void)dirtyProperties
{
    var r = [CPSet set],
        property = nil,
        objectEnumerator = [_remoteProperties objectEnumerator];

    while (property = [objectEnumerator nextObject])
    {
        var localName = [property localName];
        if (_propertyLastModified[localName] && _propertyLastModified[localName] >= lastSyncedAt)
            [r addObject:property];
    }
    return r;
}

/*!
    Every property begins 'deferred', meaning unloaded. When a property is set
    through initWithJson, updateFromJson, or a mutator, it is no longer considered
    deferred.
*/
- (BOOL)isPropertyDeferred:(CPString)localName
{
    var remotePropertiesEnumerator = [_remoteProperties objectEnumerator],
        property;
    while (property = [remotePropertiesEnumerator nextObject])
    {
        if ([property localName] == localName)
            return [_deferredProperties containsObject:property];

    }
    [CPException raise:CPInvalidArgumentException reason:@"Unable to find property " + localName + "."];
}

- (void)initWithJson:(id) js
{
    _suppressRemotePropertiesObservation = YES;
    if (self = [self init])
    {
        [self updateFromJson:js];
        _suppressRemotePropertiesObservation = NO;
        [self activateRemotePropertiesObservation];
    }
    return self;
}

- (void)setPk:(long)aPk
{
    var objectByPk = WLRemoteObjectByClassByPk[[self class]];
    if (pk !== nil && objectByPk !== undefined)
        delete objectByPk[pk];
    pk = aPk;
    [WLRemoteObject setInstance:self forPk:pk];
}

- (void)updateFromJson:js
{
    var property = nil,
        objectEnumerator = [_remoteProperties objectEnumerator];

    while (property = [objectEnumerator nextObject])
        [self updateFromJson:js remoteProperty:property];
}

- (void)updateFromJson:js preservingDirtyProperties:(BOOL)shouldPreserveDirty
{
    var property = nil,
        objectEnumerator = [_remoteProperties objectEnumerator];

    while (property = [objectEnumerator nextObject])
    {
        // If the local version is changed, don't overwrite it with the remote.
        if (shouldPreserveDirty && [[self dirtyProperties] containsObject:property])
            continue;
        [self updateFromJson:js remoteProperty:property];
    }
}

- (void)updateFromJson:js remoteProperty:(RemoteProperty)aProperty
{
    var remoteName = [aProperty remoteName];
    if (js[remoteName] !== undefined)
    {
        var value = js[remoteName],
            localName = [aProperty localName];
        if ([aProperty valueTransformer])
            value = [[aProperty valueTransformer] transformedValue:value];
        [self setValue:value forKey:localName];
        [_deferredProperties removeObject:aProperty];
    }
}

- (id)asPostJSObject
{
    var r = {},
        property = nil,
        objectEnumerator = [[self dirtyProperties] objectEnumerator];

    while (property = [objectEnumerator nextObject])
    {
        var value = [self valueForKey:[property localName]];
        if ([property valueTransformer] && [[[property valueTransformer] class] allowsReverseTransformation])
            value = [[property valueTransformer] reverseTransformedValue:value];
        r[[property remoteName]] = value;
    }

    return r;
}

- (BOOL)isEqual:(id)anObject
{
    if (self === anObject)
        return YES;

    if (![anObject isKindOfClass:[self class]])
        return NO;

    // Entries with no primary key can only be equal if they
    // are identical.
    if ([self pk] === nil)
        return NO;

    return [self pk] == [anObject pk];
}

+ (CPArray)objectsFromJson:jsonArray
{
    var r = [CPArray array];
    for(var i = 0; i < jsonArray.length; i++)
    {
        [r addObject:[[self alloc] initWithJson: jsonArray[i]]];
    }
    return r;
}

+ (void)addRemoteObject:(WLRemoteObject)anObject to:(CPObject)target inKey:(CPString)aKey
{
    var sourceArray = [target valueForKey:aKey];
    // indexOfObject first searches by isEqual which matches by PK. Then it searches
    // by identity. In both cases a match indicates we should replace.
    var index = [sourceArray indexOfObject:anObject];
    if (index != CPNotFound)
        [CPException raise:CPInvalidArgumentException reason:@"Object "+target+" already exists in array."];

    // Append to the end.
    index = sourceArray.length-1;
    var indexes = [CPIndexSet indexSetWithIndex:index];
    [target willChange:CPKeyValueChangeInsertion valuesAtIndexes:indexes forKey:aKey];
    [sourceArray insertObject:anObject atIndex:index];
    [target didChange:CPKeyValueChangeInsertion valuesAtIndexes:indexes forKey:aKey];
}

+ (void)removeRemoteObject:(WLRemoteObject)anObject from:(CPObject)target inKey:(CPString)aKey
{
    var sourceArray = [target valueForKey:aKey];
    var index = [sourceArray indexOfObject:anObject];
    if (index == CPNotFound)
        [CPException raise:CPInvalidArgumentException reason:@"Object "+target+" doesn't exists in the array."];

    var indexes = [CPIndexSet indexSetWithIndex:index];
    [target willChange:CPKeyValueChangeRemoval valuesAtIndexes:indexes forKey:aKey];
    [sourceArray removeObjectAtIndex:index];
    [target didChange:CPKeyValueChangeRemoval valuesAtIndexes:indexes forKey:aKey];
}

+ (WLRemoteObject)dummyForPk:(long)pk
{
    var remoteObject = [[WLRemoteObject alloc] init];
    [remoteObject setPk:pk];
    return remoteObject;
}

+ (void)objectByPk:(long)pk inArray:(CPArray) anArray
{
    var dummy = [WLRemoteObject dummyForPk:pk];
    var index = [anArray indexOfObject:dummy];

    if (index != CPNotFound)
    {
        return [anArray objectAtIndex:index];
    }

    return nil;
}

- (CPString)remotePath
{
    // Override this method.
}

- (BOOL)isNew
{
    return pk === nil;
}

/*!
    Create or recreate this object remotely.
*/
- (void)create
{
    [[self undoManager] registerUndoWithTarget:self
                                      selector:@selector(delete)
                                        object:nil];

    [self ensureCreated];
}

/*!
    Delete this object remotely.
*/
- (void)delete
{
    [[self undoManager] registerUndoWithTarget:self
                               selector:@selector(create)
                                 object:nil];

    [self ensureDeleted];
}

- (void)ensureCreated
{
    if (![self isNew] || createAction !== nil)
        return;

    // FIXME Should this be here or in init somewhere? In init we don't yet know if
    // this object will be loaded from remote or if it's being created.

    // Since we're creating the entry, there are no deferred fields. Without clearing
    // these, viewing the entry would lead to a pointless GET.
    _deferredProperties = [CPSet set];

    // Also consider all fields dirty so that any initial values like the name 'unnamed'
    // for a new tag gets POSTed.
    [self makeAllDirty];

    createAction = [WLRemoteAction schedule:WLRemoteActionPostType path:[self remotePath] delegate:self message:"Create " + [self description]];
}

- (void)ensureDeleted
{
    if ([self isNew] || deleteAction !== nil)
        return;

    deleteAction = [WLRemoteAction schedule:WLRemoteActionDeleteType path:[self remotePath] delegate:self message:"Delete entry"];
}

- (void)ensureLoaded
{
    if ([_deferredProperties count] == 0 || contentDownloadAction !== nil)
        return;

    // path TBD
    contentDownloadAction = [WLRemoteAction schedule:WLRemoteActionGetType path:nil delegate:self message:"Loading entry..."];
}

- (void)ensureSaved
{
    if (![self isDirty])
        return;

    // If a save action is already in the pipe, relax.
    if (saveAction !== nil) {
        if (![saveAction isStarted])
            return;

        /*
            The ongoing save is saving stale information. We must ensure
            another save will be scheduled after this one.
        */
        _mustSaveAgain = YES;
        return;
    }

    CPLog.info("Save "+self+" dirt: "+[[self dirtyProperties] description]);
    saveAction = [WLRemoteAction schedule:WLRemoteActionPutType path:nil delegate:self message:"Waiting to save entry..."];
}

- (void)remoteActionWillBegin:(WLRemoteAction)anAction
{
    if ([anAction type] == WLRemoteActionPostType)
    {
        if (pk)
        {
            CPLog.error("Attempt to create an existing entry");
            return;
        }

        [anAction setPayload:[self asPostJSObject]];
        // Assume the action will succeed or retry until it does.
        [self setLastSyncedAt:[CPDate date]];
    }
    else if ([anAction type] == WLRemoteActionDeleteType)
    {
        if (pk === nil)
        {
            CPLog.error("Attempt to delete an non existant entry");
            return;
        }

        [anAction setPayload:nil];
        // Assume the action will succeed or retry until it does.
        [self setLastSyncedAt:[CPDate date]];
        [anAction setPath:[self remotePath]+"/"+pk];
    }
    else if ([anAction type] == WLRemoteActionPutType)
    {
        if (!pk)
        {
            CPLog.error("Attempt to save non created entry "+[self description]);
            return;
        }

        [anAction setMessage:"Saving entry..."];
        [anAction setPayload:[self asPostJSObject]];
        // Assume the action will succeed or retry until it does.
        [self setLastSyncedAt:[CPDate date]];
        [anAction setPath:[self remotePath]+"/"+pk];
    }
    else if ([anAction type] == WLRemoteActionGetType)
    {
        if (!pk)
        {
            CPLog.error("Attempt to download non created entry "+[self description]);
            return;
        }

        [anAction setPath:[self remotePath]+"/"+pk];
    }
}

- (void)remoteActionDidReceivePostData:(Object)aResult
{
    // Make sure we get the new PK, but only the PK. If we update the
    // rest we'll get a bunch of empty information which may overwrite
    // changes the user is in the process of making.
    [self updateFromJson:aResult remoteProperty:[self remotePropertyForKey:"pk"]];
}

- (void)remoteActionDidFinish:(WLRemoteAction)anAction
{
    if ([anAction type] == WLRemoteActionPostType)
    {
        [WLRemoteObject setDirtProof:YES];
        [[self undoManager] disableUndoRegistration];
        [self remoteActionDidReceivePostData:[anAction result]];
        [[self undoManager] enableUndoRegistration];
        [WLRemoteObject setDirtProof:NO];
        createAction = nil;
        if ([_delegate respondsToSelector:@selector(remoteObjectWasCreated:)])
            [_delegate remoteObjectWasCreated:self];
    }
    else if ([anAction type] == WLRemoteActionDeleteType)
    {
        // The previous PK is now gone.
        [self setPk:nil];

        // There is nothing to save anymore.
        [saveAction cancel];
        saveAction = nil;

        // After the object has been deleted, the next call to 'ensureCreated' will
        // create a new object. When that creation happens all the data should be
        // considered dirty to ensure it gets sent with the creation.
        [self makeAllDirty];

        deleteAction = nil;
        [self remoteObjectWasDeleted];
    }
    else if ([anAction type] == WLRemoteActionPutType)
    {
        saveAction = nil;
        if (_mustSaveAgain) {
            _mustSaveAgain = NO;
            [self ensureSaved];
        }
    }
    else if ([anAction type] == WLRemoteActionGetType)
    {
        // Assume whatever was downloaded is the most current info, so nothing gets dirty.
        [WLRemoteObject setDirtProof:YES];
        [[self undoManager] disableUndoRegistration];
        [self updateFromJson:[anAction result]];
        [[self undoManager] enableUndoRegistration];
        [WLRemoteObject setDirtProof:NO];
        contentDownloadAction = nil;
    }
}

- (void)remoteObjectWasDeleted
{
    if ([_delegate respondsToSelector:@selector(remoteObjectWasDeleted:)])
        [_delegate remoteObjectWasDeleted:self];
}

@end

var WLRemoteObjectClassKey = "WLRemoteObjectClassKey",
    WLRemoteObjectPkKey = "WLRemoteObjectPkKey";

/*!
    TODO Do something sensible here.
*/
@implementation WLRemoteObject (CPCoding)

- (id)initWithCoder:(CPCoder)aCoder
{
    var clz = [aCoder decodeObjectForKey:WLRemoteObjectClassKey],
        pk = [aCoder decodeObjectForKey:WLRemoteObjectPkKey];

    return [WLRemoteObject instanceOf:clz withPk:pk];
}

- (void)encodeWithCoder:(CPCoder)aCoder
{
    [super encodeWithCoder:aCoder];

    [aCoder encodeObject:[self class] forKey:WLRemoteObjectClassKey];
    [aCoder encodeObject:[self pk] forKey:WLRemoteObjectPkKey];
}

@end

@implementation RemoteProperty : CPObject
{
    CPString            localName @accessors;
    CPString            remoteName @accessors;
    CPValueTransformer  valueTransformer @accessors;
}

+ (id)propertyWithName:(CPString)aName
{
    return [self propertyWithLocalName:aName remoteName:aName transformer:nil];
}

+ (id)propertyWithLocalName:(CPString)aLocalName remoteName:(CPString)aRemoteName
{
    return [self propertyWithLocalName:aLocalName remoteName:aRemoteName transformer:nil];
}

+ (id)propertyWithLocalName:(CPString)aLocalName remoteName:(CPString)aRemoteName transformer:(CPValueTransformer)aTransformer
{
    var r = [RemoteProperty new];
    [r setLocalName:aLocalName];
    [r setRemoteName:aRemoteName];
    [r setValueTransformer:aTransformer];
    return r;
}

- (BOOL)isEqual:(id)anOther
{
    return (anOther !== nil && anOther.isa && [anOther isKindOfClass:RemoteProperty] && anOther.localName == self.localName);
}

- (CPString)description
{
    return "<RemoteProperty "+remoteName+":"+localName+">";
}

@end
