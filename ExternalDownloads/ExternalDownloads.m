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

static NSArray<EDTrack *> *EDTracks(id response) {
    id items = EDGet(response, @"items");
    if (![items isKindOfClass:NSArray.class]) return nil;
    NSMutableArray *tracks = [NSMutableArray array];
    for (id item in items) {
        NSString *uri = EDString(EDGet(item, @"URL"));
        if (![uri hasPrefix:@"spotify:track:"]) continue;
        NSString *identifier = uri.lastPathComponent;
        identifier = [[identifier componentsSeparatedByString:@":"] lastObject];
        if (identifier.length != 22 || [identifier rangeOfCharacterFromSet:NSCharacterSet.alphanumericCharacterSet.invertedSet].location != NSNotFound) continue;
        EDTrack *track = [EDTrack new];
        track.identifier = identifier;
        track.title = EDString(EDGet(item, @"name"));
        id artists = EDGet(item, @"artists");
        track.artist = [artists isKindOfClass:NSArray.class] ? EDString(EDGet([artists firstObject], @"name")) : @"";
        if (!track.title.length || !track.artist.length) continue;
        track.status = @"Ожидает загрузки";
        [tracks addObject:track];
    }
    return tracks;
}

@interface EDDownloads : UITableViewController <NSURLSessionTaskDelegate>
@property(nonatomic, strong) NSMutableArray<EDTrack *> *tracks;
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
    self.title = @"Скачанные";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Остановить" style:UIBarButtonItemStylePlain target:self action:@selector(stop)];
}
- (void)close { [self.navigationController dismissViewControllerAnimated:YES completion:nil]; }
- (void)stop {
    self.running = NO;
    self.generation++;
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
    if ([self.pageURI containsString:@":collection:tracks"]) {
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
            if (!tracks) { failure(EDError(@"Spotify вернул неизвестный формат списка.")); return; }
            [self beginTracks:tracks];
        });
    };
    ((void (*)(id, SEL, id, id, id, BOOL, id, id))objc_msgSend)(loader, fetch, page, options, EDPlaylistPolicies, YES, reply, failure);
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
            if (![items isKindOfClass:NSArray.class] || !pageTracks) {
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
    for (EDTrack *track in tracks) {
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self next]; });
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
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
    if (method) method_setImplementation(method, imp_implementationWithBlock(block));
}

static void EDInstallCaptureHooks(void) {
    Class playlist = NSClassFromString(@"SPTPlaylistPlatformEsperantoDataLoader");
    NSString *selectorName = @"subscribePlaylistTracksForPlaylistURL:options:withPolicyProtocols:completion:onError:";
    SEL selector = NSSelectorFromString(selectorName);
    IMP original = class_getMethodImplementation(playlist, selector);
    EDHook(playlist, selectorName, ^id(id object, id url, id options, id policies, id reply, id failure) {
        EDPlaylistLoader = object; EDPlaylistPolicies = policies;
        return ((id (*)(id, SEL, id, id, id, id, id))original)(object, selector, url, options, policies, reply, failure);
    });
    // Modern playlist pages request metadata and track fields together.
    NSString *viewName = @"subscribePlaylistViewWithRecommendationsForPlaylistURL:options:withMetadataProtocols:andTrackProtocols:additionalMetadataExtensions:itemMetadataExtensions:replyOnMainThread:completion:onError:";
    SEL viewSelector = NSSelectorFromString(viewName);
    IMP viewOriginal = class_getMethodImplementation(playlist, viewSelector);
    EDHook(playlist, viewName, ^id(id object, id url, id options, id metadata, id policies, id extra, id itemExtra, BOOL main, id reply, id failure) {
        EDPlaylistLoader = object; EDPlaylistPolicies = policies;
        return ((id (*)(id, SEL, id, id, id, id, id, id, BOOL, id, id))viewOriginal)(object, viewSelector, url, options, metadata, policies, extra, itemExtra, main, reply, failure);
    });
    for (NSString *className in @[@"Collection_DataLoaderImpl.CollectionEsperantoDataLoader", @"SPTCollectionPlatformDataLoaderImplementation"]) {
        Class cls = NSClassFromString(className);
        NSString *name = @"subscribeAllTracksWithPolicyProtocols:options:completion:onError:";
        SEL sel = NSSelectorFromString(name);
        IMP orig = class_getMethodImplementation(cls, sel);
        EDHook(cls, name, ^id(id object, id policies, id options, id reply, id failure) {
            EDCollectionLoader = object; EDCollectionPolicies = policies; EDCollectionWasObserved = YES;
            return ((id (*)(id, SEL, id, id, id, id))orig)(object, sel, policies, options, reply, failure);
        });
    }
}

static void EDInstallDownloadHook(void) {
    Class cls = NSClassFromString(@"Offline_ContentOffliningUIImpl.ContentOffliningUIHelperImplementation");
    NSString *name = @"downloadToggledWithCurrentAvailability:addAction:removeAction:pageIdentifier:pageURI:interactionID:";
    SEL sel = NSSelectorFromString(name);
    IMP original = class_getMethodImplementation(cls, sel);
    EDHook(cls, name, ^(id object, NSInteger availability, id add, id remove, id identifier, NSURL *page, id interaction) {
        NSString *uri = page.absoluteString;
        if ([uri containsString:@":playlist:"] || [uri containsString:@":collection:tracks"]) {
            dispatch_async(dispatch_get_main_queue(), ^{ [[EDDownloads shared] openPage:page]; });
        } else ((void (*)(id, SEL, NSInteger, id, id, id, id, id))original)(object, sel, availability, add, remove, identifier, page, interaction);
    });
}

__attribute__((constructor)) static void EDInitialize(void) {
    @autoreleasepool {
        if (![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqualToString:@"9.1.0"]) return;
        EDInstallCaptureHooks();
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            // Install after Eevee's own launch-time initialization.
            dispatch_async(dispatch_get_main_queue(), ^{ EDInstallDownloadHook(); });
        }];
    }
}
