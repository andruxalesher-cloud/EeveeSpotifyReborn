#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Selectors and ABI signatures were inspected in the supplied Spotify 9.1.0 binary.
typedef void (^EDReply)(id);
typedef void (^EDFailure)(NSError *);
static __weak id EDPlaylistLoader;
static __weak id EDCollectionLoader;
static NSArray *EDPlaylistPolicies;
static NSArray *EDCollectionPolicies;
static BOOL EDCollectionWasObserved;
static __weak id EDSpotifyPlayer;
static NSMutableDictionary<NSString *, NSValue *> *EDInstalledHooks;

static Class EDClass(NSString *name) {
    Class cls = NSClassFromString(name);
    if (cls) return cls;
    NSDictionary *mangled = @{
        @"Offline_ContentOffliningUIImpl.ContentOffliningUIHelperImplementation": @"_TtC30Offline_ContentOffliningUIImpl38ContentOffliningUIHelperImplementation",
        @"NowPlaying_PlatformImpl.StatefulPlayerImplementation": @"_TtC23NowPlaying_PlatformImpl28StatefulPlayerImplementation",
        @"Collection_DataLoaderImpl.CollectionEsperantoDataLoader": @"_TtC25Collection_DataLoaderImpl29CollectionEsperantoDataLoader",
        @"ContextMenu_PlatformLegacyAdapterImpl.PresenterFactory": @"_TtC37ContextMenu_PlatformLegacyAdapterImpl16PresenterFactory",
        @"ContextMenu_InternalImpl.ContextMenuViewController": @"_TtC24ContextMenu_InternalImpl25ContextMenuViewController",
        @"Collection_DataLoaderImpl.CollectionDataLoaderTrackResponse": @"_TtC25Collection_DataLoaderImpl33CollectionDataLoaderTrackResponse"
    };
    NSString *runtimeName = mangled[name];
    return runtimeName ? objc_lookUpClass(runtimeName.UTF8String) : Nil;
}

static BOOL EDIsCollection(NSString *uri) {
    return [uri isEqualToString:@"spotify:collection"] || [uri containsString:@":collection:tracks"] ||
           [uri hasSuffix:@":collection"];
}

static NSError *EDError(NSString *message) {
    return [NSError errorWithDomain:@"ExternalDownloads" code:1
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

static id EDGet(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *EDString(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSAttributedString.class]) return [value string];
    if ([value isKindOfClass:NSURL.class]) return [value absoluteString];
    return @"";
}

static NSString *EDNormalized(NSString *value) {
    NSString *folded = [[value lowercaseString] stringByReplacingOccurrencesOfString:@"ё" withString:@"е"];
    NSArray *parts = [folded componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet];
    return [[parts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@" "];
}

static NSString *EDMatch(NSString *text, NSString *pattern) {
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
        options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    return match.numberOfRanges > 1 ? [text substringWithRange:[match rangeAtIndex:1]] : nil;
}

static NSURL *EDRoot(void) {
    return [[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject
            URLByAppendingPathComponent:@"ExternalDownloads" isDirectory:YES];
}

@interface EDTrack : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *artist;
@property(nonatomic, copy) NSString *status;
@property(nonatomic) BOOL saved;
@end
@implementation EDTrack
@end

static NSMutableDictionary<NSString *, EDTrack *> *EDKnownTracks;
static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, EDTrack *> *> *EDTracksByTitle;
static void EDRefreshRows(void);

static void EDRememberTrack(EDTrack *track) {
    if (!EDKnownTracks) EDKnownTracks = [NSMutableDictionary dictionary];
    if (!EDTracksByTitle) EDTracksByTitle = [NSMutableDictionary dictionary];
    EDKnownTracks[track.identifier] = track;
    NSString *key = EDNormalized(track.title);
    if (!EDTracksByTitle[key]) EDTracksByTitle[key] = [NSMutableDictionary dictionary];
    EDTracksByTitle[key][track.identifier] = track;
    static BOOL refreshPending;
    if (!refreshPending) {
        refreshPending = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^{
            refreshPending = NO;
            EDRefreshRows();
        });
    }
}

static EDTrack *EDTrackFromItem(id item) {
    NSString *uri = EDString(EDGet(item, @"URL"));
    if (![uri hasPrefix:@"spotify:track:"]) return nil;
    NSString *identifier = [[uri componentsSeparatedByString:@":"] lastObject];
    if (identifier.length != 22 || [identifier rangeOfCharacterFromSet:NSCharacterSet.alphanumericCharacterSet.invertedSet].location != NSNotFound) return nil;
    EDTrack *track = [EDTrack new];
    track.identifier = identifier;
    track.title = EDString(EDGet(item, @"name"));
    id artists = EDGet(item, @"artists");
    track.artist = [artists isKindOfClass:NSArray.class] ? EDString(EDGet([artists firstObject], @"name")) : @"";
    if (!track.title.length || !track.artist.length) return nil;
    track.status = @"Ожидает загрузки";
    return track;
}

static void EDRegisterItem(id item) {
    dispatch_async(dispatch_get_main_queue(), ^{
        EDTrack *track = EDTrackFromItem(item);
        if (!track) return;
        EDRememberTrack(track);
    });
}

static NSArray<EDTrack *> *EDTracks(id response) {
    id items = EDGet(response, @"items");
    if (![items isKindOfClass:NSArray.class]) return nil;
    NSMutableArray *tracks = [NSMutableArray array];
    for (id item in items) {
        EDTrack *track = EDTrackFromItem(item);
        if (!track) continue;
        [tracks addObject:track];
    }
    return tracks;
}

static void EDCaptureResponse(id response) {
    id items = EDGet(response, @"items");
    if ([items isKindOfClass:NSArray.class]) for (id item in items) EDRegisterItem(item);
}

static id EDCapturedReply(id reply) {
    if (!reply) return nil;
    return [^(id response) {
        EDCaptureResponse(response);
        ((EDReply)reply)(response);
    } copy];
}

static id EDCapturedViewReply(id reply) {
    if (!reply) return nil;
    return [^(id metadata, id tracks) {
        EDCaptureResponse(tracks);
        ((void (^)(id, id))reply)(metadata, tracks);
    } copy];
}

static id EDCapturedRecommendationsReply(id reply) {
    if (!reply) return nil;
    return [^(id metadata, id tracks, id recommendations) {
        EDCaptureResponse(tracks);
        ((void (^)(id, id, id))reply)(metadata, tracks, recommendations);
    } copy];
}

@interface EDDownloads : UITableViewController <NSURLSessionTaskDelegate>
@property(nonatomic, strong) NSMutableArray<EDTrack *> *tracks;
@property(nonatomic, strong) NSMutableArray<EDTrack *> *pendingTracks;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionTask *activeTask;
@property(nonatomic, strong) AVPlayer *player;
@property(nonatomic, copy) NSString *pageURI;
@property(nonatomic) NSUInteger cursor;
@property(nonatomic) BOOL running;
@property(nonatomic) NSUInteger generation;
@property(nonatomic, copy) NSString *statusText;
+ (instancetype)shared;
- (void)openPage:(NSURL *)page;
- (void)downloadSingleTrack:(EDTrack *)track;
- (void)loadCollectionAt:(NSUInteger)offset generation:(NSUInteger)generation accumulated:(NSMutableArray *)tracks;
@end

@implementation EDDownloads
+ (instancetype)shared {
    static EDDownloads *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] initWithStyle:UITableViewStyleInsetGrouped]; });
    return instance;
}
- (instancetype)initWithStyle:(UITableViewStyle)style {
    if ((self = [super initWithStyle:style])) {
        _tracks = [NSMutableArray array];
        _pendingTracks = [NSMutableArray array];
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForRequest = 30;
        configuration.timeoutIntervalForResource = 180;
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:NSOperationQueue.mainQueue];
        _statusText = @"Скачанные";
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Скачанные · v2";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Остановить" style:UIBarButtonItemStylePlain target:self action:@selector(stop)];
}
- (void)close { [self.navigationController dismissViewControllerAnimated:YES completion:nil]; }
- (void)stop {
    self.running = NO;
    self.generation++;
    [self.pendingTracks removeAllObjects];
    [self.activeTask cancel];
    self.activeTask = nil;
    self.statusText = @"Загрузка остановлена. Нажми «Скачать» снова для повтора.";
    [self.tableView reloadData];
}
- (void)show {
    if (self.navigationController.presentingViewController) return;
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) if (candidate.isKeyWindow) window = candidate;
    }
    UIViewController *presenter = window.rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (presenter) [presenter presentViewController:[[UINavigationController alloc] initWithRootViewController:self] animated:YES completion:nil];
}
- (void)openPage:(NSURL *)page {
    NSAssert(NSThread.isMainThread, @"Download UI must run on the main thread");
    [self show];
    if (self.running) return;
    self.pageURI = page.absoluteString;
    self.running = YES;
    NSUInteger generation = ++self.generation;
    self.statusText = @"Читаю список треков…";
    self.tracks = [NSMutableArray array];
    NSDictionary *catalog = [NSDictionary dictionaryWithContentsOfURL:[EDRoot() URLByAppendingPathComponent:@"library.plist"]];
    for (NSDictionary *entry in catalog[self.pageURI]) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        EDTrack *track = [EDTrack new];
        track.identifier = entry[@"id"]; track.title = entry[@"title"]; track.artist = entry[@"artist"];
        if (![track.identifier isKindOfClass:NSString.class] || track.identifier.length != 22 ||
            [track.identifier rangeOfCharacterFromSet:NSCharacterSet.alphanumericCharacterSet.invertedSet].location != NSNotFound) continue;
        track.saved = [NSFileManager.defaultManager fileExistsAtPath:[self fileFor:track].path];
        track.status = track.saved ? @"Скачано · нажми для воспроизведения" : @"Файл отсутствует";
        [self.tracks addObject:track];
    }
    [self.tableView reloadData];
    EDFailure failure = ^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.generation) return;
            self.running = NO;
            self.statusText = error.localizedDescription;
            [self.tableView reloadData];
        });
    };
    // A timeout leaves previously downloaded songs accessible while offline.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (generation == self.generation && self.running && [self.statusText isEqualToString:@"Читаю список треков…"]) {
            failure(EDError(@"Список треков не получен. Сохранённые песни доступны ниже."));
            self.generation++;
        }
    });
    if (EDIsCollection(self.pageURI)) {
        [self loadCollectionAt:0 generation:generation accumulated:[NSMutableArray array]];
        return;
    }
    id loader = EDPlaylistLoader;
    SEL fetch = NSSelectorFromString(@"fetchPlaylistTracksForPlaylistURL:options:withPolicyProtocols:replyOnMainThread:completion:onError:");
    id builder = [NSClassFromString(@"SPTPlaylistPlatformPlaylistTracksFetchOptionsBuilder") new];
    id options = EDGet(builder, @"build");
    if (!loader || !options || !EDPlaylistPolicies || ![loader respondsToSelector:fetch]) {
        failure(EDError(@"Не удалось подключиться к списку плейлиста. Открой плейлист заново и повтори."));
        return;
    }
    EDReply reply = ^(id response) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.generation) return;
            NSArray *tracks = EDTracks(response);
            id items = EDGet(response, @"items");
            if (!tracks || ([items count] > 0 && tracks.count == 0)) { failure(EDError(@"Spotify вернул список без названий песен.")); return; }
            SEL totalSelector = NSSelectorFromString(@"unrangedLength");
            if ([response respondsToSelector:totalSelector] &&
                ((NSUInteger (*)(id, SEL))objc_msgSend)(response, totalSelector) > [items count]) {
                failure(EDError(@"Spotify вернул только часть плейлиста. Нужна доработка чтения этого списка.")); return;
            }
            [self beginTracks:tracks];
        });
    };
    ((void (*)(id, SEL, id, id, id, BOOL, id, id))objc_msgSend)(loader, fetch, page, options, EDPlaylistPolicies, YES, reply, failure);
}
- (void)downloadSingleTrack:(EDTrack *)track {
    [self show];
    if (self.running) {
        if ([self.statusText isEqualToString:@"Читаю список треков…"]) {
            [self.pendingTracks addObject:track];
            return;
        }
        for (EDTrack *existing in self.tracks) if ([existing.identifier isEqualToString:track.identifier]) return;
        [self.tracks addObject:track];
        [self saveCatalog];
        [self.tableView reloadData];
        return;
    }
    self.pageURI = [@"spotify:track:" stringByAppendingString:track.identifier];
    self.running = YES;
    self.generation++;
    [self beginTracks:@[track]];
}
- (void)loadCollectionAt:(NSUInteger)offset generation:(NSUInteger)generation accumulated:(NSMutableArray *)tracks {
    id loader = EDCollectionLoader;
    SEL fetch = NSSelectorFromString(@"fetchAllTracksWithPolicyProtocols:options:replyOnMainThread:completion:onError:");
    id options = EDGet(EDGet(loader, @"typesFactory"), @"makeFetchOptions");
    SEL setRange = NSSelectorFromString(@"setRange:");
    if (!EDCollectionWasObserved || !loader || ![loader respondsToSelector:fetch] || ![options respondsToSelector:setRange]) {
        self.running = NO;
        self.statusText = @"Не удалось прочитать «Любимые треки». Открой список заново и повтори.";
        [self.tableView reloadData];
        return;
    }
    ((void (*)(id, SEL, NSRange))objc_msgSend)(options, setRange, NSMakeRange(offset, 200));
    EDReply reply = ^(id response) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.generation) return;
            id items = EDGet(response, @"items");
            NSArray *pageTracks = EDTracks(response);
            if (![items isKindOfClass:NSArray.class] || !pageTracks || ([items count] > 0 && pageTracks.count == 0)) {
                self.running = NO; self.statusText = @"Неизвестный формат любимых треков.";
                [self.tableView reloadData]; return;
            }
            [tracks addObjectsFromArray:pageTracks];
            if ([items count] == 200) {
                if (offset >= 100000) {
                    self.running = NO; self.statusText = @"Список слишком большой для этой тестовой сборки.";
                    [self.tableView reloadData]; return;
                }
                [self loadCollectionAt:offset + 200 generation:generation accumulated:tracks];
            } else [self beginTracks:tracks];
        });
    };
    EDFailure failure = ^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.generation) return;
            self.running = NO; self.statusText = error.localizedDescription;
            [self.tableView reloadData];
        });
    };
    ((void (*)(id, SEL, id, id, BOOL, id, id))objc_msgSend)(loader, fetch, EDCollectionPolicies ?: @[], options, YES, reply, failure);
}
- (NSURL *)fileFor:(EDTrack *)track { return [EDRoot() URLByAppendingPathComponent:[track.identifier stringByAppendingString:@".mp3"]]; }
- (void)beginTracks:(NSArray<EDTrack *> *)tracks {
    NSError *error;
    if (![NSFileManager.defaultManager createDirectoryAtURL:EDRoot() withIntermediateDirectories:YES attributes:nil error:&error]) {
        self.running = NO; self.statusText = error.localizedDescription; [self.tableView reloadData]; return;
    }
    self.tracks = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSArray *combined = [tracks arrayByAddingObjectsFromArray:self.pendingTracks];
    [self.pendingTracks removeAllObjects];
    for (EDTrack *track in combined) {
        if ([seen containsObject:track.identifier]) continue;
        [seen addObject:track.identifier];
        track.saved = [NSFileManager.defaultManager fileExistsAtPath:[self fileFor:track].path];
        track.status = track.saved ? @"Скачано · нажми для воспроизведения" : @"Ожидает загрузки";
        [self.tracks addObject:track];
    }
    self.cursor = 0;
    [self saveCatalog];
    [self next];
}
- (void)saveCatalog {
    NSURL *url = [EDRoot() URLByAppendingPathComponent:@"library.plist"];
    NSMutableDictionary *catalog = [[NSDictionary dictionaryWithContentsOfURL:url] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableArray *items = [NSMutableArray array];
    for (EDTrack *track in self.tracks) [items addObject:@{@"id":track.identifier, @"title":track.title, @"artist":track.artist}];
    catalog[self.pageURI] = items;
    NSError *error;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:catalog format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    if (!data || ![data writeToURL:url options:NSDataWritingAtomic error:&error]) self.statusText = error.localizedDescription;
}
- (void)next {
    if (!self.running) return;
    while (self.cursor < self.tracks.count && self.tracks[self.cursor].saved) self.cursor++;
    if (self.cursor == self.tracks.count) {
        self.running = NO;
        NSUInteger count = 0;
        for (EDTrack *track in self.tracks) if (track.saved) count++;
        self.statusText = [NSString stringWithFormat:@"Скачано %lu из %lu. Нажми на скачанную песню для прослушивания.", (unsigned long)count, (unsigned long)self.tracks.count];
        [self.tableView reloadData]; return;
    }
    EDTrack *track = self.tracks[self.cursor];
    track.status = @"Ищу на Muzfrog…";
    self.statusText = [NSString stringWithFormat:@"Обрабатываю %lu из %lu", (unsigned long)self.cursor + 1, (unsigned long)self.tracks.count];
    [self.tableView reloadData];
    NSMutableString *slug = [[NSString stringWithFormat:@"%@ %@", track.artist, track.title] mutableCopy];
    CFStringTransform((__bridge CFMutableStringRef)slug, NULL, kCFStringTransformToLatin, false);
    CFStringTransform((__bridge CFMutableStringRef)slug, NULL, kCFStringTransformStripDiacritics, false);
    NSString *path = [EDNormalized(slug) stringByReplacingOccurrencesOfString:@" " withString:@"-"];
    NSURL *page = [NSURL URLWithString:[@"https://mob.muzfrog.com/view/" stringByAppendingString:path]];
    // The supplied source URL is an explicit match for this Spotify recording.
    if ([track.identifier isEqualToString:@"3jy14G6E0lcNdK9i6h4Uup"]) page = [NSURL URLWithString:@"https://mob.muzfrog.com/view/temnyy-princ-vklube"];
    NSUInteger generation = self.generation;
    self.activeTask = [self.session dataTaskWithURL:page completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.generation) return;
            NSString *html = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
            NSString *heading = EDMatch(html ?: @"", @"<h1[^>]*>(.*?)</h1>");
            NSString *expected = EDNormalized([NSString stringWithFormat:@"%@ %@ Скачать", track.artist, track.title]);
            if (error || ((NSHTTPURLResponse *)response).statusCode != 200 || ![EDNormalized(heading ?: @"") isEqualToString:expected]) {
                [self finishTrack:track error:error ?: EDError(@"Точное совпадение на источнике не найдено")]; return;
            }
            NSString *source = EDMatch(html, @"mp3source=\"([^\"]+)\"");
            source = [[source stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\\"]];
            NSURL *url = [NSURL URLWithString:source ?: @""];
            if (![url.scheme isEqualToString:@"https"] || ![url.host isEqualToString:@"dl.muzfrog.net"]) {
                [self finishTrack:track error:EDError(@"Источник не предоставил ссылку на MP3")]; return;
            }
            [self download:url track:track generation:generation];
        });
    }];
    [self.activeTask resume];
}
- (void)download:(NSURL *)url track:(EDTrack *)track generation:(NSUInteger)generation {
    track.status = @"Скачиваю…";
    [self.tableView reloadData];
    self.activeTask = [self.session downloadTaskWithURL:url completionHandler:^(NSURL *temporary, NSURLResponse *response, NSError *error) {
        // URLSession removes the temporary file when this callback returns.
        if (generation != self.generation) return;
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSString *mime = response.MIMEType.lowercaseString;
        if (!error && (http.statusCode != 200 || ![mime hasPrefix:@"audio/"])) error = EDError(@"Сервер вернул ошибку вместо аудио");
        if (!error) {
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:temporary options:nil];
            if (!asset.playable || [asset tracksWithMediaType:AVMediaTypeAudio].count == 0) error = EDError(@"Файл не удалось распознать как аудио");
        }
        if (!error) {
            NSURL *destination = [self fileFor:track];
            if (![NSFileManager.defaultManager fileExistsAtPath:destination.path]) [NSFileManager.defaultManager moveItemAtURL:temporary toURL:destination error:&error];
        }
        NSError *result = error;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation == self.generation) [self finishTrack:track error:result];
        });
    }];
    [self.activeTask resume];
}
- (void)finishTrack:(EDTrack *)track error:(NSError *)error {
    track.saved = error == nil;
    track.status = error ? error.localizedDescription : @"Скачано · нажми для воспроизведения";
    self.cursor++;
    [self.tableView reloadData];
    // Serial downloads avoid duplicate writes and keep source requests modest.
    NSUInteger generation = self.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (generation == self.generation) [self next];
    });
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    NSString *host = request.URL.host.lowercaseString;
    BOOL allowed = [request.URL.scheme isEqualToString:@"https"] &&
        ([host isEqualToString:@"mob.muzfrog.com"] || [host isEqualToString:@"dl.muzfrog.net"]);
    completionHandler(allowed ? request : nil);
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.tracks.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return self.statusText; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"track"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"track"];
    EDTrack *track = self.tracks[path.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%@ — %@", track.artist, track.title];
    cell.textLabel.numberOfLines = 2;
    cell.detailTextLabel.text = track.status;
    cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryType = track.saved ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    EDTrack *track = self.tracks[path.row];
    if (!track.saved) return;
    SEL pause = NSSelectorFromString(@"setIsPaused:");
    if ([EDSpotifyPlayer respondsToSelector:pause]) ((void (*)(id, SEL, BOOL))objc_msgSend)(EDSpotifyPlayer, pause, YES);
    NSError *error;
    [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback error:&error];
    if (!error) [AVAudioSession.sharedInstance setActive:YES error:&error];
    if (error) { self.statusText = error.localizedDescription; [self.tableView reloadData]; return; }
    [self.player pause];
    self.player = [AVPlayer playerWithURL:[self fileFor:track]];
    AVPlayerViewController *controller = [AVPlayerViewController new];
    controller.player = self.player;
    [self presentViewController:controller animated:YES completion:^{ [self.player play]; }];
}
@end

static void EDHook(Class cls, NSString *name, id block) {
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
    if (!method) return;
    if (!EDInstalledHooks) EDInstalledHooks = [NSMutableDictionary dictionary];
    NSString *key = [NSStringFromClass(cls) stringByAppendingFormat:@"/%@", name];
    NSValue *saved = EDInstalledHooks[key];
    IMP replacement = saved ? (IMP)saved.pointerValue : imp_implementationWithBlock(block);
    // Retain the first implementation so repeated lifecycle events cannot wrap our own hook.
    if (!saved) EDInstalledHooks[key] = [NSValue valueWithPointer:replacement];
    if (method_getImplementation(method) != replacement) class_replaceMethod(cls, NSSelectorFromString(name), replacement, method_getTypeEncoding(method));
}

static void EDInstallCaptureHooks(void) {
    // Capture full track identities independently of which list loader builds the visible rows.
    for (NSString *className in @[@"Collection_DataLoaderImpl.CollectionDataLoaderTrackResponse", @"SPTPlaylistPlatformPlaylistTrackEsperantoImplementation"]) {
        Class cls = EDClass(className);
        for (NSString *name in @[@"setName:", @"setURL:", @"setArtists:"]) {
            SEL selector = NSSelectorFromString(name);
            IMP original = class_getMethodImplementation(cls, selector);
            EDHook(cls, name, ^(id object, id value) {
                ((void (*)(id, SEL, id))original)(object, selector, value);
                EDRegisterItem(object);
            });
        }
    }
    Class playerClass = EDClass(@"NowPlaying_PlatformImpl.StatefulPlayerImplementation");
    SEL playerSelector = NSSelectorFromString(@"player:stateDidChange:");
    IMP playerOriginal = class_getMethodImplementation(playerClass, playerSelector);
    EDHook(playerClass, NSStringFromSelector(playerSelector), ^(id object, id player, id state) {
        dispatch_async(dispatch_get_main_queue(), ^{ EDSpotifyPlayer = object; });
        ((void (*)(id, SEL, id, id))playerOriginal)(object, playerSelector, player, state);
    });
    Class playlist = NSClassFromString(@"SPTPlaylistPlatformEsperantoDataLoader");
    NSString *selectorName = @"subscribePlaylistTracksForPlaylistURL:options:withPolicyProtocols:completion:onError:";
    SEL selector = NSSelectorFromString(selectorName);
    IMP original = class_getMethodImplementation(playlist, selector);
    EDHook(playlist, selectorName, ^id(id object, id url, id options, id policies, id reply, id failure) {
        dispatch_async(dispatch_get_main_queue(), ^{ EDPlaylistLoader = object; EDPlaylistPolicies = [policies copy]; });
        return ((id (*)(id, SEL, id, id, id, id, id))original)(object, selector, url, options, policies, EDCapturedReply(reply), failure);
    });
    // Modern playlist pages request metadata and track fields together.
    NSString *viewName = @"subscribePlaylistViewWithRecommendationsForPlaylistURL:options:withMetadataProtocols:andTrackProtocols:additionalMetadataExtensions:itemMetadataExtensions:replyOnMainThread:completion:onError:";
    SEL viewSelector = NSSelectorFromString(viewName);
    IMP viewOriginal = class_getMethodImplementation(playlist, viewSelector);
    EDHook(playlist, viewName, ^id(id object, id url, id options, id metadata, id policies, id extra, id itemExtra, BOOL main, id reply, id failure) {
        dispatch_async(dispatch_get_main_queue(), ^{ EDPlaylistLoader = object; EDPlaylistPolicies = [policies copy]; });
        return ((id (*)(id, SEL, id, id, id, id, id, id, BOOL, id, id))viewOriginal)(object, viewSelector, url, options, metadata, policies, extra, itemExtra, main, EDCapturedRecommendationsReply(reply), failure);
    });
    for (NSString *name in @[@"subscribePlaylistViewForPlaylistURL:options:withMetadataProtocols:andTrackProtocols:additionalMetadataExtensions:itemMetadataExtensions:completion:onError:",
                             @"fetchPlaylistViewForPlaylistURL:options:withMetadataProtocols:andTrackProtocols:additionalMetadataExtensions:itemMetadataExtensions:completion:onError:"]) {
        SEL sel = NSSelectorFromString(name);
        IMP orig = class_getMethodImplementation(playlist, sel);
        if ([name hasPrefix:@"subscribe"]) {
            EDHook(playlist, name, ^id(id object, id url, id options, id metadata, id policies, id extra, id itemExtra, id reply, id failure) {
                dispatch_async(dispatch_get_main_queue(), ^{ EDPlaylistLoader = object; EDPlaylistPolicies = [policies copy]; });
                return ((id (*)(id, SEL, id, id, id, id, id, id, id, id))orig)(object, sel, url, options, metadata, policies, extra, itemExtra, EDCapturedViewReply(reply), failure);
            });
        } else {
            EDHook(playlist, name, ^(id object, id url, id options, id metadata, id policies, id extra, id itemExtra, id reply, id failure) {
                dispatch_async(dispatch_get_main_queue(), ^{ EDPlaylistLoader = object; EDPlaylistPolicies = [policies copy]; });
                ((void (*)(id, SEL, id, id, id, id, id, id, id, id))orig)(object, sel, url, options, metadata, policies, extra, itemExtra, EDCapturedViewReply(reply), failure);
            });
        }
    }
    for (NSString *className in @[@"Collection_DataLoaderImpl.CollectionEsperantoDataLoader", @"SPTCollectionPlatformDataLoaderImplementation"]) {
        Class cls = EDClass(className);
        NSString *name = @"subscribeAllTracksWithPolicyProtocols:options:completion:onError:";
        SEL sel = NSSelectorFromString(name);
        IMP orig = class_getMethodImplementation(cls, sel);
        EDHook(cls, name, ^id(id object, id policies, id options, id reply, id failure) {
            dispatch_async(dispatch_get_main_queue(), ^{ EDCollectionLoader = object; EDCollectionPolicies = [policies copy]; EDCollectionWasObserved = YES; });
            return ((id (*)(id, SEL, id, id, id, id))orig)(object, sel, policies, options, EDCapturedReply(reply), failure);
        });
        NSString *fetchName = @"fetchAllTracksWithPolicyProtocols:options:replyOnMainThread:completion:onError:";
        SEL fetch = NSSelectorFromString(fetchName);
        IMP fetchOriginal = class_getMethodImplementation(cls, fetch);
        EDHook(cls, fetchName, ^(id object, id policies, id options, BOOL main, id reply, id failure) {
            dispatch_async(dispatch_get_main_queue(), ^{ EDCollectionLoader = object; EDCollectionPolicies = [policies copy]; EDCollectionWasObserved = YES; });
            ((void (*)(id, SEL, id, id, BOOL, id, id))fetchOriginal)(object, fetch, policies, options, main, EDCapturedReply(reply), failure);
        });
    }
}

static void EDInstallDownloadHook(void) {
    Class cls = EDClass(@"Offline_ContentOffliningUIImpl.ContentOffliningUIHelperImplementation");
    NSString *name = @"downloadToggledWithCurrentAvailability:addAction:removeAction:pageIdentifier:pageURI:interactionID:";
    SEL sel = NSSelectorFromString(name);
    IMP original = class_getMethodImplementation(cls, sel);
    EDHook(cls, name, ^(id object, NSInteger availability, id add, id remove, id identifier, NSURL *page, id interaction) {
        NSString *uri = page.absoluteString;
        if ([uri containsString:@":playlist:"] || EDIsCollection(uri)) {
            dispatch_async(dispatch_get_main_queue(), ^{ [[EDDownloads shared] openPage:page]; });
        } else if ([uri containsString:@":album:"] || [uri containsString:@":episode:"] || [uri containsString:@":show:"]) {
            ((void (*)(id, SEL, NSInteger, id, id, id, id, id))original)(object, sel, availability, add, remove, identifier, page, interaction);
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                EDDownloads *downloads = [EDDownloads shared];
                [downloads show];
                downloads.statusText = [NSString stringWithFormat:@"Неизвестная страница: %@ (%@). Пришли снимок этого сообщения.", uri ?: @"без URI", identifier ?: @""];
                [downloads.tableView reloadData];
            });
        }
    });
}

static EDTrack *EDMenuTrack;
static NSDate *EDMenuDate;

static void EDRememberMenu(id uriValue, id titleValue, id artistValue) {
    NSString *uri = EDString(uriValue);
    EDMenuTrack = nil;
    EDMenuDate = NSDate.date;
    if (![uri hasPrefix:@"spotify:track:"]) return;
    NSString *identifier = [[uri componentsSeparatedByString:@":"] lastObject];
    if (identifier.length != 22 || [identifier rangeOfCharacterFromSet:NSCharacterSet.alphanumericCharacterSet.invertedSet].location != NSNotFound) return;
    NSString *title = EDString(titleValue);
    NSString *artist = EDString(artistValue);
    if (!title.length || !artist.length) return;
    EDTrack *track = [EDTrack new];
    track.identifier = identifier; track.title = title; track.artist = artist;
    track.status = @"Ожидает загрузки";
    EDMenuTrack = track;
    EDRememberTrack(track);
}

static UITableView *EDFindTable(UIView *view) {
    if ([view isKindOfClass:UITableView.class]) return (UITableView *)view;
    for (UIView *child in view.subviews) {
        UITableView *table = EDFindTable(child);
        if (table) return table;
    }
    return nil;
}

static void EDInstallTrackMenuHooks(void) {
    for (NSString *className in @[@"SPTContextMenuPresenterFactoryImplementation", @"ContextMenu_PlatformLegacyAdapterImpl.PresenterFactory"]) {
        Class cls = EDClass(className);
        NSString *name = @"contextMenuPresenterForHeaderImageURL:headerImagePlaceholder:imageStyle:title:subtitle:metadataTitle:actions:entityURL:headerSubtitleStyle:senderView:options:";
        SEL selector = NSSelectorFromString(name);
        IMP original = class_getMethodImplementation(cls, selector);
        EDHook(cls, name, ^id(id object, id image, id placeholder, NSInteger style, id title, id subtitle, id metadata, id actions, id entity, NSInteger subtitleStyle, id sender, id options) {
            EDRememberMenu(entity, title, subtitle);
            return ((id (*)(id, SEL, id, id, NSInteger, id, id, id, id, id, NSInteger, id, id))original)(object, selector, image, placeholder, style, title, subtitle, metadata, actions, entity, subtitleStyle, sender, options);
        });
        NSString *trackName = @"contextMenuPresenterForTrackWithTrackURI:trackName:trackMetadata:playable:imageURL:artists:albumName:albumURI:viewURI:contextSourceURI:metadataTitle:logContext:senderView:options:actions:";
        SEL trackSelector = NSSelectorFromString(trackName);
        IMP trackOriginal = class_getMethodImplementation(cls, trackSelector);
        EDHook(cls, trackName, ^id(id object, id uri, id title, id metadata, BOOL playable, id image, id artists, id album, id albumURI, id viewURI, id contextURI, id metadataTitle, id logContext, id sender, id options, id actions) {
            id result = ((id (*)(id, SEL, id, id, id, BOOL, id, id, id, id, id, id, id, id, id, id, id))trackOriginal)(object, trackSelector, uri, title, metadata, playable, image, artists, album, albumURI, viewURI, contextURI, metadataTitle, logContext, sender, options, actions);
            id firstArtist = [artists isKindOfClass:NSArray.class] ? [artists firstObject] : artists;
            NSString *artist = EDString(firstArtist);
            if (!artist.length) artist = EDString(EDGet(firstArtist, @"name"));
            EDRememberMenu(uri, title, artist);
            return result;
        });
    }
    Class cls = EDClass(@"ContextMenu_InternalImpl.ContextMenuViewController");
    SEL selector = @selector(viewDidAppear:);
    IMP original = class_getMethodImplementation(cls, selector);
    EDHook(cls, NSStringFromSelector(selector), ^(UIViewController *controller, BOOL animated) {
        ((void (*)(id, SEL, BOOL))original)(controller, selector, animated);
        EDTrack *track = EDMenuTrack;
        if (!track || -EDMenuDate.timeIntervalSinceNow > 10) return;
        UITableView *table = EDFindTable(controller.view);
        if (!table || [table.tableFooterView.accessibilityIdentifier isEqualToString:@"external-download-track"]) return;
        UIView *existing = table.tableFooterView;
        CGFloat previousHeight = existing.frame.size.height;
        UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, table.bounds.size.width, previousHeight + 60)];
        footer.accessibilityIdentifier = @"external-download-track";
        if (existing) [footer addSubview:existing];
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.frame = CGRectMake(16, previousHeight + 6, MAX(table.bounds.size.width - 32, 100), 48);
        button.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [button setTitle:@"  Скачать трек" forState:UIControlStateNormal];
        [button setImage:[UIImage systemImageNamed:@"arrow.down.circle"] forState:UIControlStateNormal];
        button.tintColor = [UIColor colorWithRed:0.12 green:0.84 blue:0.38 alpha:1];
        button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        button.accessibilityLabel = [NSString stringWithFormat:@"Скачать трек %@", track.title];
        [button addAction:[UIAction actionWithHandler:^(UIAction *action) {
            UIViewController *sheet = controller.navigationController ?: controller;
            if (sheet.presentingViewController) {
                [sheet dismissViewControllerAnimated:YES completion:^{ [[EDDownloads shared] downloadSingleTrack:track]; }];
            } else [[EDDownloads shared] downloadSingleTrack:track];
        }] forControlEvents:UIControlEventTouchUpInside];
        [footer addSubview:button];
        table.tableFooterView = footer;
    });
}

@interface EDTrackDownloadButton : UIButton
@property(nonatomic, strong) EDTrack *track;
@end
@implementation EDTrackDownloadButton
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self setImage:[UIImage systemImageNamed:@"arrow.down.circle"] forState:UIControlStateNormal];
        self.tintColor = [UIColor colorWithRed:0.12 green:0.84 blue:0.38 alpha:1];
        self.accessibilityIdentifier = @"external-download-track-row";
        [self addTarget:self action:@selector(download) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}
- (void)download {
    if (self.track) [[EDDownloads shared] downloadSingleTrack:self.track];
}
@end

static void EDCollectRowText(UIView *view, NSMutableSet<NSString *> *texts, NSUInteger depth) {
    if (!depth || [view isKindOfClass:EDTrackDownloadButton.class]) return;
    if (view.accessibilityLabel.length) [texts addObject:EDNormalized(view.accessibilityLabel)];
    if ([view isKindOfClass:UILabel.class]) {
        NSString *text = ((UILabel *)view).text;
        if (text.length) [texts addObject:EDNormalized(text)];
    }
    for (UIView *child in view.subviews) EDCollectRowText(child, texts, depth - 1);
}

static char EDRowButtonKey;
static void EDUpdateRowButton(UIView *cell, UIView *content) {
    if (!cell.window || !content) return;
    UIResponder *responder = cell;
    while (responder && ![responder isKindOfClass:UIViewController.class]) responder = responder.nextResponder;
    if ([responder isKindOfClass:EDDownloads.class]) return;
    EDTrackDownloadButton *button = objc_getAssociatedObject(cell, &EDRowButtonKey);
    NSMutableSet *texts = [NSMutableSet set];
    EDCollectRowText(content, texts, 8);
    NSString *combined = [NSString stringWithFormat:@" %@ ", [[texts allObjects] componentsJoinedByString:@" "]];
    NSMutableDictionary *matches = [NSMutableDictionary dictionary];
    for (NSString *text in texts) {
        for (EDTrack *track in [EDTracksByTitle[text] allValues]) {
            NSString *artist = [NSString stringWithFormat:@" %@ ", EDNormalized(track.artist)];
            if ([combined containsString:artist]) matches[track.identifier] = track;
        }
    }
    // Ambiguous editions never inherit a download button for an unrelated recording.
    EDTrack *track = matches.count == 1 ? matches.allValues.firstObject : nil;
    if (!track) { button.track = nil; button.hidden = YES; return; }
    if (!button) {
        button = [[EDTrackDownloadButton alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(cell, &EDRowButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [content addSubview:button];
    }
    button.track = track;
    button.hidden = NO;
    button.accessibilityLabel = [NSString stringWithFormat:@"Скачать трек %@", track.title];
    button.frame = CGRectMake(MAX(content.bounds.size.width - 92, 0), MAX((content.bounds.size.height - 44) / 2, 0), 44, 44);
    [content bringSubviewToFront:button];
}

static void EDInstallRowHooks(void) {
    for (Class cls in @[UITableViewCell.class, UICollectionViewCell.class]) {
        SEL selector = @selector(layoutSubviews);
        IMP original = class_getMethodImplementation(cls, selector);
        EDHook(cls, NSStringFromSelector(selector), ^(UIView *cell) {
            ((void (*)(id, SEL))original)(cell, selector);
            EDUpdateRowButton(cell, EDGet(cell, @"contentView"));
        });
    }
}

static void EDRefreshRowViews(UIView *view) {
    if ([view isKindOfClass:UITableViewCell.class] || [view isKindOfClass:UICollectionViewCell.class]) {
        EDUpdateRowButton(view, EDGet(view, @"contentView"));
        return;
    }
    for (UIView *child in view.subviews) EDRefreshRowViews(child);
}

static UIWindow *EDActiveWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) if (window.isKeyWindow) return window;
    }
    return nil;
}

static void EDRefreshRows(void) { EDRefreshRowViews(EDActiveWindow()); }

static void EDShowLoadedMarker(void) {
    static BOOL shown;
    UIWindow *window = EDActiveWindow();
    if (shown || !window) return;
    shown = YES;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(20, window.safeAreaInsets.top + 6, window.bounds.size.width - 40, 34)];
    label.text = @"Модуль загрузок v2 загружен";
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    label.textColor = UIColor.whiteColor;
    label.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.95];
    label.layer.cornerRadius = 10;
    label.clipsToBounds = YES;
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [window addSubview:label];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [label removeFromSuperview]; });
}

static void EDActivate(void) {
    EDInstallCaptureHooks();
    EDInstallDownloadHook();
    EDInstallTrackMenuHooks();
    EDInstallRowHooks();
    EDShowLoadedMarker();
    static BOOL retryScheduled;
    if (!retryScheduled) {
        retryScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            EDInstallCaptureHooks();
            EDInstallDownloadHook();
            EDInstallTrackMenuHooks();
            EDInstallRowHooks();
            EDShowLoadedMarker();
        });
    }
}

__attribute__((constructor)) static void EDInitialize(void) {
    @autoreleasepool {
        for (NSString *event in @[UIApplicationDidFinishLaunchingNotification, UIApplicationDidBecomeActiveNotification]) {
            [NSNotificationCenter.defaultCenter addObserverForName:event object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                dispatch_async(dispatch_get_main_queue(), ^{ EDActivate(); });
            }];
        }
        // Also works when a signing tool loads injected libraries after the launch notification.
        dispatch_async(dispatch_get_main_queue(), ^{ EDActivate(); });
    }
}
