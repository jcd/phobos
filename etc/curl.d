// Written in the D programming language.

/*
  TODO:

  Round 1 reviews:
  $(LREF...) bugs
  DONE: rethink byLine/... to not return string in order to prevent allocations
          they should return char[]/ubyte[]
  DONE: 80 chars 
  DONE: Http.Result etc.
  DONE: gramma for http.postData
  DONE: len -> length
  DONE: perform http request -> perform a http ...
  DONE: authMethod to property
  DONE: curltimecond alias into module
  DONE: followlocatil to maxredirs
  DONE: http not class
  DONE: timecondition use std.datetime
  DONE: timeouts use core.duration
  DONE: Spelling "callbacks is not supported"
  DONE: refer to HTTP RFC describing the methods
  DONE: login/password example
  DONE: chuncked -> chunked
  DONE: max redirs; use uint.max and not -1
  DONE: isRunning returining short
  DONE: 4 chars tabs in examples.
  DONE: no space in examples.
  
  
  Disable FTP for now
  FTP byline/bychunk

  POST InputRange
  Receive OutputRange?
  
  NO: Should send/recv use special structs in order not to mess with other spawned communications?

  Future improvements:

  Progress may be deprecated in the future
  Typed http headers - Johannes Pfau
      (waiting for std.protocol.http to be accepted)
*/

/**
Curl client functionality as provided by libcurl. 

Most of the methods are available both as a synchronous and an
asynchronous version. Http.get() is the synchronous version of a
standard HTTP GET request that will return a Http.Result when all
content has been received from the server. Http.getAsync() is the
asynchronous version that will spawn a thread in the background and
return a Http.AsyncResult immediately. You can read data from the
result at later point in time. This allows you to start processing
vdata before all data has been received.

Example:
---
// Simple GET with default timeout etc.
writeln( Http.get("http://www.google.com").toString() ); // .headers for headers etc.

// GET with custom data receivers 
Http http = Http("http://www.google.com");
http.onReceiveHeader = 
    (const(char)[] key, const(char)[] value) { writeln(key ~ ": " ~ value); };
http.onReceive = (ubyte[] data) { /+ drop +/ };
http.perform;

// GET using an asynchronous range
foreach (line; Http.getAsync("http://www.google.com").byLine()) {
    // Do some expensive processing on the line while more lines are
    // received asyncronously in the background.
    writeln("asyncLine: ", line);
}

// PUT with data senders 
string msg = "Hello world";
http.onSend = (void[] data) { 
    if (msg.empty) return 0; 
    auto m = cast(void[])msg;
    typeof(size_t) length = m.length;
    data[0..length] = m[0..$];  
    msg.length = 0;
    return length;
};
http.method = Http.Method.put; // defaults to POST
http.contentLength = 11; // defaults to chunked transfer if not specified
http.perform;

// Track progress
http.method = Http.Method.get;
http.url = "http://upload.wikimedia.org/wikipedia/commons/" 
           "5/53/Wikipedia-logo-en-big.png";
http.onReceive = (ubyte[]) { };
http.onProgress = (double dltotal, double dlnow, 
                   double ultotal, double ulnow) {
    writeln("Progress ", dltotal, ", ", dlnow, ", ", ultotal, ", ", ulnow);
    return 0;
};
http.perform;
---

Source: $(PHOBOSSRC etc/_curl.d)

Copyright: Copyright Jonas Drewsen 2011-2012
License:  <a href="http://www.boost.org/LICENSE_1_0.txt">Boost License 1.0</a>.
Authors:  $(WEB steamwinter.com, Jonas Drewsen)
Credits:  The functionally is based on $(WEB _curl.haxx.se, libcurl). 
          LibCurl is licensed under a MIT/X derivate license.
*/
/*
         Copyright Jonas Drewsen 2011 - 2012.
Distributed under the Boost Software License, Version 1.0.
   (See accompanying file LICENSE_1_0.txt or copy at
         http://www.boost.org/LICENSE_1_0.txt)
*/
module etc.curl;

import etc.c.curl;
import std.conv;  
import std.string; 
import std.regex; 
import std.stream;
import std.algorithm; 
import std.encoding;
import std.concurrency; 
import std.typecons;
import std.exception;
import std.datetime;
import std.traits;
import core.thread;

version(unittest) {
    import std.stdio;
    import std.c.stdlib;
    import std.range;
    //  const string testUrl1 = "http://www.fileformat.info/info/unicode/block/latin_supplement/utf8test.htm";
    const string testUrl1 = "http://d-programming-language.appspot.com/testUrl1";
    const string testUrl2 = "http://d-programming-language.appspot.com/testUrl2";
}
version(StdDdoc) import std.stdio;

pragma(lib, "curl");

extern (C) {
    void exit(int c);
}

/*
  Wrapper class to provide a better interface to libcurl than using
  the plain C API.  It is recommended to use the Http/Ftp
  etc. classes instead unless you need the basic access to libcurl.
*/
private struct Curl {

    static this() {
        // initialize early to prevent thread races
        if (curl_global_init(CurlGlobal.all))
            throw new CurlException("Couldn't initialize libcurl");
    }
 
    static ~this() {
        curl_global_cleanup();
    }

    alias void[] outdata;
    alias ubyte[] indata;
    bool stopped;

    // A handle should not be used bu two thread simultanously
    private CURL* handle;
    private size_t delegate(outdata) _onSend; // May also return CURL_READFUNC_ABORT or CURL_READFUNC_PAUSE
    private void delegate(indata) _onReceive;
    private void delegate(const(char)[]) _onReceiveHeader;
    private CurlSeek delegate(long,CurlSeekPos) _onSeek;
    private int delegate(curl_socket_t,CurlSockType) _onSocketOption;
    private int delegate(double dltotal, double dlnow, double ultotal, double ulnow) _onProgress;

    /**
       Default constructor. Remember to set at least the $(D url)
       property before calling $(D perform())
    */
    this(bool dummy) {
        handle = curl_easy_init();
        stopped = false;
        CURL* curl = curl_easy_init();
        set(CurlOption.verbose, 1L); 
    }

    ~this() {
        if (!stopped)
            curl_easy_cleanup(this.handle);
    }

    private void _check(CURLcode code) {
        if (code != CurlError.ok) {
            throw new Exception(to!string(curl_easy_strerror(code)));
        }
    }

    private void throwOnStopped() {
        if (stopped) 
            throw new CurlException("Curl instance called after being cleaned up");
    }
    
    /** 
        Stop and invalidate this curl instance.
    */
    void cleanup() {
        throwOnStopped();
        stopped = true;
        curl_easy_cleanup(this.handle);
    }

    /**
       Pausing and continuing transfers
    */
    void pause(bool sendingPaused, bool receivingPaused) {
        throwOnStopped();
        _check(curl_easy_pause(this.handle, 
                               (sendingPaused ? CurlPause.send_cont : CurlPause.send) |
                               (receivingPaused ? CurlPause.recv_cont : CurlPause.recv)));
    }

    /**
       Set a string curl option.
       Params:
       option = A $(XREF etc.c.curl, CurlOption) as found in the curl documentation
       value = The string
    */
    void set(CURLoption option, const(char)[] value) {
        throwOnStopped();
        _check(curl_easy_setopt(this.handle, option, toStringz(value)));
    }

    /**
       Set a long curl option.
       Params:
       option = A $(XREF etc.c.curl, CurlOption) as found in the curl documentation
       value = The long
    */
    void set(CURLoption option, long value) {
        throwOnStopped();
        _check(curl_easy_setopt(this.handle, option, value));
    }

    /**
       Set a void* curl option.
       Params:
       option = A $(XREF etc.c.curl, CurlOption) as found in the curl documentation
       value = The pointer
    */
    void set(CURLoption option, void* value) {
        throwOnStopped();
        _check(curl_easy_setopt(this.handle, option, value));
    }

    /**
       Clear a pointer option
       Params:
       option = A $(XREF etc.c.curl, CurlOption) as found in the curl documentation
    */
    void clear(CURLoption option) {
        throwOnStopped();
        _check(curl_easy_setopt(this.handle, option, cast(void*)0));
    }

    /**
       perform the curl request by doing the HTTP,FTP etc. as it has
       been setup beforehand.
    */
    void perform() {
        throwOnStopped();
        _check(curl_easy_perform(this.handle));
    }

    /**
       The event handler that receives incoming data.

       Params:
       callback = the callback that recieves the ubyte[] data.
       Be sure to copy the incoming data and not store
       a slice.
       Example:
       ----
curl.onReceive = (ubyte[] data) { writeln("Got data", cast(char[]) data); };
       ----
    */
    @property ref Curl onReceive(void delegate(indata) callback) {
        _onReceive = (indata id) { 
            if (stopped)
                throw new CurlException("Receive callback called on cleaned up Curl instance");
            callback(id);
        };
        set(CurlOption.file, cast(void*) &this);
        set(CurlOption.writefunction, cast(void*) &Curl._receiveCallback);
        return this;
    }

    /**
       The event handler that receives incoming headers for protocols
       that uses headers.

       Params:
       callback = the callback that recieves the header string.
       Make sure the callback copies the incoming params if
       it needs to store it because they are references into
       the backend and may very likely change.
       Example:
       ----
mycurl.onReceiveHeader = (const(char)[] header) { writeln(header); };
       ----
    */
    @property ref Curl onReceiveHeader(void delegate(const(char)[]) callback) {
        _onReceiveHeader = (const(char)[] od) {
            if (stopped)
                throw new CurlException("Receive header callback called on cleaned up Curl instance");
            callback(od);
        };
        set(CurlOption.writeheader, cast(void*) &this);
        set(CurlOption.headerfunction, cast(void*) &Curl._receiveHeaderCallback);
        return this;
    }

    /**
       The event handler that gets called when data is needed for sending.

       Params:
       callback = the callback that has a void[] buffer to be filled
    
       Returns:
       The callback returns the number of elements in the buffer that has been filled and is ready to send.

       Example:
       ----
string msg = "Hello world";
http.onSend = delegate size_t(void[] data) { 
if (msg.empty) return 0; 
auto m = cast(void[])msg;
auto l = m.length;
data[0..l] = m[0..$];  
msg.length = 0;
return l;
};
       ----
    */
    @property ref Curl onSend(size_t delegate(outdata) callback) {
        _onSend = (outdata od) {
            if (stopped)
                throw new CurlException("Send callback called on cleaned up Curl instance");
            return callback(od);
        };
        set(CurlOption.infile, cast(void*) &this);
        set(CurlOption.readfunction, cast(void*) &Curl._sendCallback);
        return this;
    }

    /**
       The event handler that gets called when the curl backend needs to seek the 
       data to be sent.

       Params:
       callback = the callback that receives a seek offset and a seek position $(XREF etc.c.curl, CurlSeekPos)
    
       Returns:
       The callback returns the success state of the seeking $(XREF etc.c.curl, CurlSeek)

       Example:
       ----
http.onSeek = (long p, CurlSeekPos sp) { 
return CurlSeek.cantseek;
};
       ----
    */
    @property ref Curl onSeek(CurlSeek delegate(long, CurlSeekPos) callback) {
        _onSeek = (long ofs, CurlSeekPos sp) { 
            if (stopped)
                throw new CurlException("Seek callback called on cleaned up Curl instance");
            return callback(ofs, sp);
        };
        set(CurlOption.seekdata, cast(void*) &this);
        set(CurlOption.seekfunction, cast(void*) &Curl._seekCallback);
        return this;
    }

    /**
       The event handler that gets called when the net socket has been created but a 
       connect() call has not yet been done. This makes it possible to set misc. socket
       options.
    
       Params:
       callback = the callback that receives the socket and socket type $(XREF etc.c.curl, CurlSockType)
    
       Returns:
       Return 0 from the callback to signal success, return 1 to signal error and make curl close the socket

       Example:
       ----
http.onSocketOption = delegate int(curl_socket_t s, CurlSockType t) { /+ do stuff +/ };
       ----
    */
    @property ref Curl onSocketOption(int delegate(curl_socket_t, CurlSockType) callback) {
        _onSocketOption = (curl_socket_t sock, CurlSockType st) {
            if (stopped)
                throw new CurlException("Socket option callback called on cleaned up Curl instance");
            return callback(sock, st);
        };
        set(CurlOption.sockoptdata, cast(void*) &this);
        set(CurlOption.sockoptfunction, cast(void*) &Curl._socketOptionCallback);
        return this;
    }

    /**
       The event handler that gets called to inform of upload/download progress.
    
       Params:
       callback = the callback that receives the (total bytes to download, currently downloaded bytes,
       total bytes to upload, currently uploaded bytes).
    
       Returns:
       Return 0 from the callback to signal success, return non-zero to abort transfer

       Example:
       ----
http.onProgress = delegate int(double dl, double dln, double ul, double ult) { 
writeln("Progress: downloaded ", dln, " of ", dl);
writeln("Progress: uploaded ", uln, " of ", ul);  
       };
       ----
    */
    @property ref Curl onProgress(int delegate(double dltotal, double dlnow, double ultotal, double ulnow) callback) {
        _onProgress = (double dlt, double dln, double ult, double uln) {
            if (stopped)
                throw new CurlException("Progress callback called on cleaned up Curl instance");
            return callback(dlt, dln, ult, uln);
        };
        set(CurlOption.noprogress, 0);
        set(CurlOption.progressdata, cast(void*) &this);
        set(CurlOption.progressfunction, cast(void*) &Curl._progressCallback);
        return this;
    }
 
    // Internal C callbacks to register with libcurl
    extern (C) private static size_t _receiveCallback(const char* str, size_t size, size_t nmemb, void* ptr) {
        Curl* b = cast(Curl*) ptr;
        if (b._onReceive != null)
            b._onReceive(cast(indata)(str[0..size*nmemb]));
        return size*nmemb;
    }

    extern (C) private static size_t _receiveHeaderCallback(const char* str, size_t size, size_t nmemb, void* ptr) {
        Curl* b = cast(Curl*) ptr;
        auto s = str[0..size*nmemb].chomp;
        if (b._onReceiveHeader != null) 
            b._onReceiveHeader(s); 

        return size*nmemb;
    }

    extern (C) private static size_t _sendCallback(char *str, size_t size, size_t nmemb, void *ptr)           
    {                                                                                         
        Curl* b = cast(Curl*) ptr;
        void[] a = cast(void[]) str[0..size*nmemb];
        if (b._onSend == null)
            return 0;
        return b._onSend(a);
    }

    extern (C) private static int _seekCallback(void *ptr, curl_off_t offset, int origin)           
    {                                                                                         
        Curl* b = cast(Curl*) ptr;
        if (b._onSeek == null)
            return CurlSeek.cantseek;

        // origin: CurlSeekPos.set/current/end
        // return: CurlSeek.ok/fail/cantseek
        return b._onSeek(cast(long) offset, cast(CurlSeekPos) origin);
    }

    extern (C) private static int _socketOptionCallback(void *ptr, curl_socket_t curlfd, curlsocktype purpose)          
    {                                                                                         
        Curl* b = cast(Curl*) ptr;
        if (b._onSocketOption == null)
            return 0;

        // return: 0 ok, 1 fail
        return b._onSocketOption(curlfd, cast(CurlSockType) purpose);
    }

    extern (C) private static int _progressCallback(void *ptr, double dltotal, double dlnow, double ultotal, double ulnow)
    {                                                                                         
        Curl* b = cast(Curl*) ptr;
        if (b._onProgress == null)
            return 0;

        // return: 0 ok, 1 fail
        return b._onProgress(dltotal, dlnow, ultotal, ulnow);
    }

}


/**
  Mixin template for all supported curl protocols. 
  This documentation should really be in the Http struct but
  the documenation tool does not support a mixin to put its
  doc strings where a mixin is done.
*/
private mixin template Protocol() {

    Curl curl;

    /**
       True if the instance is stopped an invalid.
    */
    @property bool isStopped() {
        return curl.stopped;
    }

    /// Stop and invalidate this instance
    void cleanup() {
        curl.cleanup();
    }

    /// Connection settings

    /// Set timeout for activity on connection
    @property void dataTimeout(Duration d) {
        curl.set(CurlOption.timeout_ms, d.total!"msecs"());
    }

    /// Set timeout for connecting
    @property void connectTimeout(Duration d) {
        curl.set(CurlOption.connecttimeout_ms, d.total!"msecs"());
    }
 
    /// Network settings

    /// The URL to specify the location of the resource
    @property void url(in const(char)[] url) {
        curl.set(CurlOption.url, url);
    }

    /// DNS lookup timeout
    @property void dnsTimeout(Duration d) {
        curl.set(CurlOption.dns_cache_timeout, d.total!"msecs"());
    }

    /**
       The network interface to use in form of the the IP of the interface.
       Example:
       ----
theprotocol.netInterface = "192.168.1.32";
       ----
    */
    @property void netInterface(const(char)[] i) {
        curl.set(CurlOption.intrface, cast(char*)i);
    }

    /**
       Set the local outgoing port to use.
       Params:
       port = the first outgoing port number to try and use
       range = if the first port is occupied then try this many 
       port number forwards
    */
    void setLocalPortRange(int port, int range) {
        curl.set(CurlOption.localport, cast(long)port);
        curl.set(CurlOption.localportrange, cast(long)range);
    }

    /// Set the tcp nodelay socket option on or off
    @property void tcpNoDelay(bool on) {
        curl.set(CurlOption.tcp_nodelay, cast(long) (on ? 1 : 0) );
    }

    /// Authentication settings

    /**
       Set the usename, pasword and optionally domain for authentication purposes.
    
       Some protocols may need authentication in some cases. Use this
       function to provide credentials.

       Params:
       username = the username
       password = the password
       domain = used for NTLM authentication only and is set to the NTLM domain name
    */
    void setUsernameAndPassword(const(char)[] username, const(char)[] password, const(char)[] domain = "") {
        if (domain != "")
            username = domain ~ "/" ~ username;
        curl.set(CurlOption.userpwd, cast(char*)(username ~ ":" ~ password));
    }

    unittest {
        if (!netAllowed) return;
        Http http = Http("http://www.protected.com");
        http.onReceiveHeader = 
            (const(char)[] key, const(char)[] value) { writeln(key ~ ": " ~ value); };
        http.onReceive = (ubyte[] data) { /+ drop +/ };
        http.setUsernameAndPassword("myuser", "mypassword");
        http.perform;
    }

    /**
       See $(XREF curl, Curl.onReceive)
    */
    @property void onReceive(void delegate(ubyte[]) callback) {
        curl.onReceive(callback);
    }

    /**
       See $(XREF curl, Curl.onProgress)
    */
    @property void onProgress(int delegate(double dltotal, double dlnow, double ultotal, double ulnow) callback) {
        curl.onProgress(callback);
    }
}

/*
  Decode ubyte[] array using the provided EncodingScheme up to maxChars
  Returns: Tuple of ubytes read and the Char[] characters decoded.
           Not all ubytes are guaranteed to be read in case of decoding error.
*/
private Tuple!(size_t,Char[]) decodeString(Char = char)(const(ubyte)[] data, 
                                                        EncodingScheme scheme,
                                                        size_t maxChars = size_t.max) {
    Char[] res;
    size_t startLen = data.length;
    size_t charsDecoded = 0;
    while (data.length && charsDecoded < maxChars) {
        dchar dc = scheme.safeDecode(data);
        if (dc == INVALID_SEQUENCE) {
            return typeof(return)(size_t.max, cast(Char[])null);
        }
        charsDecoded++;
        res ~= dc;
    }
    return typeof(return)(startLen-data.length, res);
}

/*
  Decode ubyte[] array using the provided EncodingScheme until a the
  line terminator specified is found. Base src is effectively
  concatenated with src as the first thing.

  Returns: true if a terminator was found 
           Not all ubytes are guaranteed to be read in case of decoding error.
	   any decoded chars will be inserted into dst.
*/
private bool decodeLineInto(Terminator, Char = char)(ref ubyte[] basesrc, 
                                                     ref ubyte[] src, ref Char[] dst,
						     EncodingScheme scheme,
						     Terminator terminator) {
    Char[] res;
    size_t startLen = src.length;
    size_t charsDecoded = 0;
    // if there is anything in the basesrc then try to decode that
    // first.
    if (basesrc.length != 0) {
        // Try to ensure 4 entries in the basesrc by copying from src.
        size_t blen = basesrc.length;
        size_t len = (basesrc.length + src.length) >= 4 ? 4 : basesrc.length + src.length;
        basesrc.length = len;
        dchar dc = scheme.safeDecode(basesrc);
        if (dc == INVALID_SEQUENCE) {
            if (len == 4)
                throw new CurlException("Invalid code sequence");
            return false;
        }
        dst ~= dc;
        src = src[len-basesrc.length-blen .. $]; // remove used ubytes from src
	basesrc.length = 0;
    }

    while (src.length) {
        dchar dc = scheme.safeDecode(src);
        if (dc == INVALID_SEQUENCE) {
            return false;
        }
        dst ~= dc;
        
        if (dst.endsWith(terminator)) 
            return true;
    }
    return false; // no terminator found
}

/**
   Http client functionality.
*/
struct Http {

    mixin Protocol;

    static private uint defaultMaxRedirects = 10;

    private curl_slist * headerChunk = null; // outgoing http headers

    /// The status line of the final subrequest in a request
    StatusLine status;
    private void delegate(StatusLine) _onReceiveStatusLine;

    /// The HTTP method to use
    public Method method = Method.get;

    /** Time condition enumeration:
        none
        ifmodsince
        ifunmodsince
        lastmod
        last
    */
    alias CurlTimeCond TimeCond;

    /**
       Constructor taking the url as parameter.
    */
    this(in const(char)[] url) {
        curl = Curl(true);
        curl_slist_free_all(headerChunk);
        curl.set(CurlOption.url, url);
    }

    /// Add a header string e.g. "X-CustomField: Something is fishy"
    void addHeader(in const(char)[] key, in const(char)[] value) {
        headerChunk = curl_slist_append(headerChunk, cast(char*) toStringz(key ~ ": " ~ value)); 
    }

    /// Add a header string e.g. "X-CustomField: Something is fishy"
    private void addHeader(in const(char)[] header) {
        headerChunk = curl_slist_append(headerChunk, cast(char*) toStringz(header)); 
    }

    // Set the active cookie string e.g. "name1=value1;name2=value2"
    void setCookie(in const(char)[] cookie) {
        curl.set(CurlOption.cookie, cookie);
    }

    /// Set a filepath to where a cookie jar should be read/stored
    void setCookieJar(in const(char)[] path) {
        curl.set(CurlOption.cookiefile, path);
        curl.set(CurlOption.cookiejar, path);
    }

    /// Flush cookie jar to disk
    void flushCookieJar() {
        curl.set(CurlOption.cookielist, "FLUSH");
    }

    /// Clear session cookies
    void clearSessionCookies() {
        curl.set(CurlOption.cookielist, "SESS");
    }

    /// Clear all cookies
    void clearAllCookies() {
        curl.set(CurlOption.cookielist, "ALL");
    }

    /**
       Set time condition on the request.

       Parameters:
       cond:  CurlTimeCond.{none,ifmodsince,ifunmodsince,lastmod}
       secsSinceEpoch: The time value
    */
    void setTimeCondition(CurlTimeCond cond, DateTime timestamp) {
        curl.set(CurlOption.timecondition, cond);
        long secsSinceEpoch = (timestamp - DateTime(1970, 1, 1)).total!"seconds";
        curl.set(CurlOption.timevalue, secsSinceEpoch);
    }

    /** Convenience function that simply does a HTTP HEAD on the
        specified URL. 

        Example:
        ----
auto res = Http.head("http://www.digitalmars.com")
writeln(res.headers["Content-Length"]);
        ----
     
        Returns:
        A $(XREF _curl, Result) object.
    */
    static Result head(in const(char)[] url) {
        Result res;
        auto client = Http(url);
        client.method = Method.head;
        client.onReceiveHeader = (const(char)[] key,const(char)[] value) { res.addHeader(key, value); };
        client.onReceiveStatusLine = (StatusLine l) { res.reset(); res.statusLine = l; };
        client.maxRedirects = Http.defaultMaxRedirects;
        client.perform;
        return res;
    }

    unittest {
        if (!netAllowed) return;
        auto res = Http.head(testUrl1);
        auto sl = res.statusLine;
        assert(sl.majorVersion == 1, "head() statusLine majorVersion is not 1 ");
        assert(sl.code == 200, "head() statusLine code is not 200");
        assert(res.headers["content-type"] == "text/plain;charset=utf-8", "head() content-type is incorrect");
    }

    /** Asynchronous HTTP HEAD to the specified URL. 
        Callbacks are not supported when using this method (e.g. onReceive).

        Example:
        ----
auto res = Http.headAsync("http://www.digitalmars.com");
writeln(res.byChunk(100).front);
        ----

        Returns:
        A $(XREF _curl, AsyncResult) object.
    */
    static AsyncResult headAsync(string url) {
        return AsyncResult(url, "", "", Method.head);
    }

    unittest {
        if (!netAllowed) return;
        auto res = Http.headAsync(testUrl1);
        res.byChunk(1).empty;
        auto sl = res.statusLine;
        assert(sl.majorVersion == 1, "headAsync() statusLine majorVersion is not 1");
        assert(sl.code == 200, "headAsync() statusLine code is not 200");
        assert(res.headers["content-type"] == "text/plain;charset=utf-8", "headAsync() content-type is incorrect");
    }

    /** Convenience function that simply does a HTTP GET on the
        specified URL. 
     
        Example:
        ----
auto res = Http.get("http://www.digitalmars.com");
writeln(res.toString());
        ----

        Returns:
        A $(XREF _curl, Result) object.
    */
    static Result get(in const(char)[] url) {
        Result res;
        auto client = Http(url);
        client.onReceive = (ubyte[] data) { res._bytes ~= data; };
        client.onReceiveHeader = (const(char)[] key,const(char)[] value) { res.addHeader(key, value); };
        client.onReceiveStatusLine = (StatusLine l) { res.reset(); res.statusLine = l; };
        client.maxRedirects = Http.defaultMaxRedirects;
        client.perform;
        return res;
    }

    unittest {
        if (!netAllowed) return;
        auto res = Http.get(testUrl1);
        assert(res.bytes[0..11] == [72, 101, 108, 108, 111, 32, 119, 111, 114, 108, 100], "get() returns unexpected content " ~ to!string(res.bytes[0..11]));
        assert(res.toString()[0..11] == "Hello world", "get() returns unexpected text "); 
    }

    /** Asynchronous HTTP GET to the specified URL. 
        Callbacks are not supported when using this method (e.g. onReceive).

        Example:
        ----
auto res = Http.getAsync("http://www.digitalmars.com");
writeln(res.byChunk(100).front);
        ----

        Returns:
        A $(XREF _curl, AsyncResult) object.
    */
    static AsyncResult getAsync(string url) {
        return AsyncResult(url, "", "", Method.get);
    }

    unittest {
        if (!netAllowed) return;
        auto res = Http.getAsync(testUrl1);
        auto byline = res.byLine(true);
        assert(byline.front[0..11] == "Hello world", "getAsync() returns unexpected text");
        auto wlen = walkLength(byline);
        assert(wlen == 1, "Did not read 1 lines getAsync().byLine() but " ~ to!string(wlen));
        
        res = Http.getAsync(testUrl1);
        auto bychunk = res.byChunk(100);
        assert(bychunk.front[0..11] == [72, 101, 108, 108, 111, 32, 119, 111, 114, 108, 100], 
               "getAsync().byChunk() returns unexpected content");
        wlen = walkLength(bychunk);
    }

    /** Convenience function that simply does a HTTP POST on the
        specified URL. 

        Example:
        ----
auto res = Http.post("http://d-programming-language.appspot.com/testUrl2", [1,2,3,4]);
writeln(res.toString());
        ----

        Returns:
        A $(XREF _curl, Result) object.
    */
    static Result post(in const(char)[] url, const(void)[] postData, const(char)[] contentType = "application/octet-stream") {
        auto client = Http(url);
        Result res;
        client.onSend = delegate size_t(void[] buf) {
            size_t minlen = min(buf.length, postData.length);
            buf[0..minlen] = postData[0..minlen];
            postData = postData[minlen..$];
            return minlen;
        };
        client.addHeader("Content-Type: " ~ contentType);
        client.contentLength = postData.length;
        client.onReceive = (ubyte[] idata) { res._bytes ~= idata; };
        client.onReceiveHeader = (const(char)[] key,const(char)[] value) { res.addHeader(key, value); };
        client.onReceiveStatusLine = (StatusLine l) { res.reset(); res.statusLine = l; };
        client.maxRedirects = Http.defaultMaxRedirects;
        client.perform;
        return res;
    }

    unittest {
        if (!netAllowed) return;
        auto res = Http.post(testUrl2, [72, 101, 108, 108, 111, 32, 119, 111, 114, 108, 100]);
        assert(res.bytes[0..11] == [72, 101, 108, 108, 111, 32, 119, 111, 114, 108, 100], 
               "post() returns unexpected content " ~ to!string(res.bytes[0..11]));
    }

    /// ditto
    static Result post(in const(char)[] url, const(char)[] postData, const(char)[] contentType = "text/plain; charset=utf-8") {
        return post(url, cast(const(void)[]) postData, contentType);
    }

    unittest {
        if (!netAllowed) return;
        auto res = Http.post(testUrl2, "Hello world");
        assert(res.toString()[0..11] == "Hello world", "post() returns unexpected text "); 
    }

    /** Convenience POST function as the one above but for associative arrays that
        will get application/form-url-encoded.
    */
    static Result post(in const(char)[] url, string[string] params) {
        // TODO: url encode params
        string delim = "";
        string data = "";
        foreach (key; params.byKey()) {
            data ~= delim ~ key ~ "=" ~ params[key];
        }
        // string data = joiner(map!(delegate (string a) { return a ~ '=' ~ params[a]; })(params.keys), '&');
        return post(url, cast(immutable(void)[]) data, "application/form-url-encoded");
    }

    unittest {
        if (!netAllowed) return;
        string[string] fields;
        fields["Hello"] = "World";
        auto res = Http.post(testUrl2, fields);
        assert(res.toString()[0..11] == "Hello=World", "post() returns unexpected text"); 
    }

    struct Pool(DATA) {
    private:
        struct Entry {
            DATA data;
            Entry * next;
        };
        Entry * root;
	Entry * freeList;
    public:
	bool empty() {
            return root == null;
	}
	void push(DATA d) {
            if (freeList == null) {
                // Allocate new Entry since there is no one 
                // available in tht freeList
                freeList = new Entry;
            }
            freeList.data = d;
            Entry * oldroot = root;
            root = freeList;
            freeList = freeList.next;
            root.next = oldroot;
	}
	DATA pop() {
            DATA d = root.data;
            Entry * n = root.next;
            root.next = freeList;
            freeList = root;
            root = n;
            return d;
	}
    };
     
    // Internal messages send between threads. 
    // The data is wrapped in this struct in order to ensure that 
    // other std.concurrency.receive calls does not pick up our messages
    // by accident.
    private struct Message(T) {
        public T data;
    }

    private static Message!T message(T)(T data) {
        return Message!T(data);
    }

    // Spawn a thread for handling the reading of incoming data in the
    // background while the delegate is executing.  This will optimize
    // throughput by allowing simultanous input (this struct) and
    // output (AsyncHttpLineOutputRange).
    private static void _spawnAsyncRequest(Unit,Terminator = void)(string _url, immutable(void)[] _data, 
								   string _contentType, Method method) {

        auto client = Http(_url);
        Result res;
        Tid fromTid = receiveOnly!(Tid);

	// Get buffer to read into
        Pool!(Unit[]) freeBuffers;  // Free list of buffer objects
	
        // Number of bytes filled into active buffer
        Unit[] buffer;
	bool bufferValid = false;

        static if ( !is(Terminator == void)) {
            // Only lines reading will receive a terminator
            Terminator terminator = receiveOnly!Terminator;
            bool keepTerminator = receiveOnly!bool;
            EncodingScheme encodingScheme;
            // max number of bytes to carry over from an onReceive
            // callback. This is 4 because it is the max code units to
            // decode a code point in the supported encodings.
	    ubyte[] leftOverBytes =  new ubyte[4];
            leftOverBytes.length = 0;
         } else {
            Unit[] outdata;
        }

        client.onReceive = (ubyte[] data) { 

            // Make sure the last received statusLine is sent to main
            // thread before receiving. 
            if (res.statusLine.majorVersion != 0) {
                fromTid.send(thisTid(), message(res.statusLine));
                foreach (key; res.headers.byKey()) {
                    fromTid.send(thisTid(), message(Tuple!(string,string)(key,res.headers[key])));
                }
                res.statusLine.majorVersion = 0;
            }

            // If no terminator is specified the chunk size is fixed.
            static if ( is(Terminator == void) ) {

                // Copy data to fill active buffer
                while (data.length != 0) {
                    
                    // Make sure we have a buffer
                    while ( outdata.length == 0 && freeBuffers.empty) {
                        // Active buffer is invalid and there are no
                        // available buffers in the pool. Wait for buffers
                        // to return from main thread in order to reuse
                        // them.
                        receive((immutable(Unit)[] buf) {
                                buffer = cast(Unit[])buf;
                                outdata = buffer[];
                            },
                            (bool flag) { client.cleanup(); }
                            );
                        if (client.isStopped) return;
                    }
                    if (outdata.length == 0) {
                        buffer = freeBuffers.pop();
                        outdata = buffer[];
                    }
                    
                    // Copy data
                    size_t copyBytes = outdata.length < data.length ? outdata.length : data.length;

                    outdata[0..copyBytes] = data[0..copyBytes];
                    outdata = outdata[copyBytes..$];
                    data = data[copyBytes..$];

                    if (outdata.length == 0) {
                        fromTid.send(thisTid(), message(cast(immutable(Unit)[])buffer));
                    }
                }
            } else {
                // Terminator is specified and buffers should be
                // resized as determined by the terminator
                
                // Copy data to active buffer until terminator is
                // found.
                if (encodingScheme is null)
                    encodingScheme = res.encodingScheme;

		// Decode as many lines as possible
                while (true) {

                    // Make sure we have a buffer
                    while (!bufferValid && freeBuffers.empty) {
                        // Active buffer is invalid and there are no
                        // available buffers in the pool. Wait for buffers
                        // to return from main thread in order to reuse
                        // them.
                        receive((immutable(Unit)[] buf) {
                                buffer = cast(Unit[])buf;
                                buffer.length = 0;
                                bufferValid = true;
                            },
                            (bool flag) { client.cleanup(); }
                            );
                        if (client.isStopped) return;
                    }
                    if (!bufferValid) {
                        buffer = freeBuffers.pop();
                        bufferValid = true;
                    }

                    // Try to read a line from left over bytes from
                    // last onReceive plus the newly received bytes. 
                    try { 
                        if (decodeLineInto(leftOverBytes, data, buffer,
                                           encodingScheme, terminator)) {
                            if (keepTerminator) {
                                fromTid.send(thisTid(), message(cast(immutable(Unit)[])buffer));
                            } else {
                                static if (isArray!Terminator)
                                    fromTid.send(thisTid(), message(cast(immutable(Unit)[])buffer[0..$-terminator.length]));
                                else
                                    fromTid.send(thisTid(), message(cast(immutable(Unit)[])buffer[0..$-1]));
                            }
                            bufferValid = false;
                        } else {
                            // Could not decode an entire line. Save
                            // bytes left in data for next call to
                            // onReceive. Can be up to a max of 4 bytes.
                            enforce(data.length <= 4, new CurlException("Too many bytes left not decoded"));
                            leftOverBytes ~= data;
			    break;
			}
                    } catch (CurlException) {
                        // Encoding is wrong. abort.
                        client.cleanup();
                        return;
                    }
		}
            }
        };

        client.method = method;

        if (method == Method.post || method == Method.put) {
            client.onSend = delegate size_t(void[] buf) {
                receiveTimeout(0, (bool x) { client.cleanup(); });
                if (client.isStopped) return CurlReadFunc.abort;
                size_t minlen = min(buf.length, _data.length);
                buf[0..minlen] = _data[0..minlen];
                _data = _data[minlen..$];
                return minlen;
            };
            client.addHeader("Content-Type: " ~ _contentType);
            client.contentLength = _data.length;
        }

        client.onReceiveHeader = (const(char)[] key,const(char)[] value) { 
            receiveTimeout(0, (bool x) { client.cleanup(); });
            if (client.isStopped) return;
            res.addHeader(key, value); 
        };

        client.onReceiveStatusLine = (StatusLine l) { 
            receiveTimeout(0, (bool x) { client.cleanup(); });
            if (client.isStopped) return;
            res.reset(); 
            res.statusLine = l;
        };

        client.maxRedirects = Http.defaultMaxRedirects;
	
        // Start the request
        client.perform;

        if (client.isStopped) return;

        // Send the status line and headers if they haven't been so
        if (res.statusLine.majorVersion != 0) {
            fromTid.send(thisTid(), message(res.statusLine));
            foreach (key; res.headers.byKey()) {
                fromTid.send(thisTid(), message(Tuple!(string,string)(key,res.headers[key])));
            }
            res.statusLine.majorVersion = 0;
        }

        // Send remaining data that is not a full chunk size
        static if ( is(Terminator == void) ) {
            //            if (bufferValid && bufferUsed > 0) {
            if (outdata.length != 0) {
                // Resize the last buffer
                buffer.length = buffer.length - outdata.length;
                fromTid.send(thisTid(), message(cast(immutable(ubyte)[])buffer));
            }
        } else {
            if (bufferValid && buffer.length != 0) {
                fromTid.send(thisTid(), message(cast(immutable(Unit)[])buffer[0..$]));
            }
        }

        fromTid.send(thisTid(), message(true)); // signal done
    }

    /** Async HTTP POST to the specified URL. 
        Callbacks are not supported when using this method (e.g. onReceive).

        Example:
        ----
auto res = Http.postAsync("http://d-programming-language.appspot.com/testUrl2", 
                          "Posting this data");
writeln(res.byChunk(100).front);
        ----

        Returns:
        A $(XREF _curl, AsyncResult) object.
    */
    static AsyncResult postAsync(string url, immutable(void)[] postData, string contentType = "application/octet-stream") {
        return AsyncResult(url, postData, contentType, Method.post);
    }

    unittest {
        if (!netAllowed) return;
        auto res = Http.postAsync(testUrl2, [72, 101, 108, 108, 111, 32, 119, 111, 114, 108, 100]);
        auto byline = res.byLine();
	auto line = byline.front;
        assert(line[0..11] == "Hello world", "postAsync() returns unexpected text");
        auto wlen = walkLength(byline);
        assert(wlen == 1, "Did not read 1 lines postAsync().byLine() but " ~ to!string(wlen));

        res = Http.postAsync(testUrl2, [72, 101, 108, 108, 111, 32, 119, 111, 114, 108, 100]);
        auto bychunk = res.byChunk(100);
        assert(bychunk.front[0..11] == [72, 101, 108, 108, 111, 32, 119, 111, 114, 108, 100], 
               "postAsync().byChunk() returns unexpected content");
        wlen = walkLength(bychunk);
    }

    /// ditto
    static AsyncResult postAsync(string url, string data, string contentType = "text/plain; charset=utf-8") {
        return postAsync(url, cast(immutable(void)[]) data, contentType);
    }

    unittest {
        if (!netAllowed) return;
        auto res = Http.postAsync(testUrl2, "Hello world");
        auto byline = res.byLine();
        assert(byline.front[0..11] == "Hello world", "postAsync() returns unexpected text");
        auto wlen = walkLength(byline);
        assert(wlen == 1, "Did not read 1 lines postAsync().byLine() but " ~ to!string(wlen));
    }

    /** Convenience asynchrounous POST function as the one above but for
        associative arrays that will get application/form-url-encoded.
    */
    static AsyncResult postAsync(string url, string[string] params) {
        // TODO: url encode params
        string delim = "";
        string data = "";
        foreach (key; params.byKey()) {
            data ~= delim ~ key ~ "=" ~ params[key];
            delim = "&";
        }
        // string data = joiner(map!(delegate (string a) { return a ~ '=' ~ params[a]; })(params.keys), '&');
        return postAsync(url, cast(immutable(void)[]) data, "application/form-url-encoded");
    }

    unittest {
        if (!netAllowed) return;
        string[string] fields;
        fields["Hello"] = "World";
        auto res = Http.postAsync(testUrl2, fields);
        auto byline = res.byLine();
        assert(byline.front[0..11] == "Hello=World", "postAsync() returns unexpected text");
        auto wlen = walkLength(byline);
        assert(wlen == 1, "Did not read 1 lines postAsync().byLine() but " ~ to!string(wlen));
    }

    /** Convenience function that simply does a HTTP PUT on the
        specified URL. 

        Example:
        ----
auto res = Http.put("http://d-programming-language.appspot.com/testUrl2", 
                    "Putting this data");
writeln(res.code);
        ----

        Returns:
        A $(XREF _curl, Result) object.
    */
    static Result put(in const(char)[] url, const(void)[] putData, const(char)[] contentType = "application/octet-stream") {
        auto client = Http(url);
        Result res;
        client.method = Method.put;
        client.onSend = delegate size_t(void[] buf) {
            size_t minlen = min(buf.length, putData.length);
            buf[0..minlen] = putData[0..minlen];
            putData = putData[minlen..$];
            return minlen;
        };

        client.addHeader("Content-Type: " ~ contentType);
        client.contentLength = putData.length;
        client.onReceive = (ubyte[] idata) { res._bytes ~= idata; };
        client.onReceiveHeader = (const(char)[] key,const(char)[] value) { res.addHeader(key, value); };
        client.onReceiveStatusLine = (StatusLine l) { res.reset(); res.statusLine = l; };
        client.maxRedirects = Http.defaultMaxRedirects;
        client.perform;
        return res;
    }

    unittest {
        if (!netAllowed) return;
        auto res = Http.put(testUrl2, [72, 101, 108, 108, 111, 32, 119, 111, 114, 108, 100]);
        assert(res.bytes[0..11] == [72, 101, 108, 108, 111, 32, 119, 111, 114, 108, 100], 
               "put() returns unexpected content " ~ to!string(res.bytes[0..11]));
    }

    /// ditto
    static Result put(in const(char)[] url, const(char)[] putData, const(char)[] contentType = "text/plain; charset=utf-8") {
        return put(url, cast(const(void)[]) putData, contentType);
    }

    unittest {
        if (!netAllowed) return;
        auto res = Http.put(testUrl2, "Hello world");
        assert(res.toString()[0..11] == "Hello world", "put() returns unexpected text "); 
    }

    /** Asynchronous HTTP PUT to the specified URL. 
        Callbacks are not supported when using this method (e.g. onReceive).

        Example:
        ----
auto res = Http.putAsync("http://d-programming-language.appspot.com/testUrl2", 
                         "Posting this data");
writeln(res.byChunk(100).front);
        ----

        Returns:
        A $(XREF _curl, AsyncResult) object.
    */
    static AsyncResult putAsync(string url, immutable(void)[] putData, string contentType = "application/octet-stream") {
        return AsyncResult(url, putData, contentType, Method.put);
    }

    unittest {
        if (!netAllowed) return;
        auto res = Http.putAsync(testUrl2, [72, 101, 108, 108, 111, 32, 119, 111, 114, 108, 100]);
        auto byline = res.byLine();
        assert(byline.front[0..11] == "Hello world", "putAsync() returns unexpected text");
        auto wlen = walkLength(byline);
        assert(wlen == 1, "Did not read 1 lines putAsync().byLine() but " ~ to!string(wlen));

        res = Http.putAsync(testUrl2, [72, 101, 108, 108, 111, 32, 119, 111, 114, 108, 100]);
        auto bychunk = res.byChunk(100);
        assert(bychunk.front[0..11] == [72, 101, 108, 108, 111, 32, 119, 111, 114, 108, 100], 
               "putAsync().byChunk() returns unexpected content");
        wlen = walkLength(bychunk);
    }

    /// ditto
    static AsyncResult putAsync(string url, string putData, string contentType = "text/plain; charset=utf-8") {
        return putAsync(url, cast(immutable(void)[]) putData, contentType);
    }

    unittest {
        if (!netAllowed) return;
        auto res = Http.putAsync(testUrl2, "Hello world");
        auto byline = res.byLine();
        assert(byline.front[0..11] == "Hello world", "putAsync() returns unexpected text");
        auto wlen = walkLength(byline);
        assert(wlen == 1, "Did not read 1 lines putAsync().byLine() but " ~ to!string(wlen));
    }

    /** Convenience function that simply does a HTTP DELETE on the
        specified URL. 

        Example:
        ----
auto res = Http.del("http://d-programming-language.appspot.com/testUrl2");
writeln(res.toString());
        ----
     
        Returns:
        A $(XREF _curl, Result) object.
    */
    static Result del(in const(char)[] url) {
        auto client = Http(url);
        Result res;
        client.method = Method.del;
        client.onReceive = (ubyte[] data) { res._bytes ~= data; };
        client.onReceiveHeader = (const(char)[] key,const(char)[] value) { res.addHeader(key, value); };
        client.onReceiveStatusLine = (StatusLine l) { res.reset(); res.statusLine = l; };
        client.maxRedirects = Http.defaultMaxRedirects;
        client.perform;
        return res;
    }

    unittest {
        if (!netAllowed) return;
        assert(Http.del(testUrl2).toString()[0..11] == "Hello world", "del() received incorrect data");
    }

    /** Asynchronous version of del().  
        See_Also: getAsync()
    */
    static AsyncResult delAsync(string url) {
        return AsyncResult(url, "", "", Method.del);
    }

    unittest {
        if (!netAllowed) return;
        assert(Http.delAsync(testUrl2).byLine().front[0..11] == "Hello world", "delAsync() received unexpected data");
    }

    /** Convenience function that simply does a HTTP OPTIONS on the
        specified URL.

        Example:
        ----
auto res = Http.options("http://www.digitalmars.com");
writeln(res.toString());
        ----
     
        Returns:
        A $(XREF _curl, Result) object.
    */
    static Result options(in const(char)[] url) {
        auto client = Http(url);
        Result res;
        client.method = Method.options;
        client.onReceive = (ubyte[] data) { res._bytes ~= data; };
        client.onReceiveHeader = (const(char)[] key,const(char)[] value) { res.addHeader(key, value); };
        client.onReceiveStatusLine = (StatusLine l) { res.reset(); res.statusLine = l; };
        client.maxRedirects = Http.defaultMaxRedirects;
        client.perform;
        return res;
    }

    unittest {
        if (true ||!netAllowed) return;
        assert(Http.options(testUrl2).toString()[0..11] == "Hello world", "options() received incorrect data");
    }

    /** Asynchronous version of options(). 
        See_Also: getAsync()
    */
    static AsyncResult optionsAsync(string url) {
        return AsyncResult(url, "", "", Method.options);
    }

    unittest {
        if (!netAllowed) return;
        assert(Http.optionsAsync(testUrl2).byLine().front[0..11] == "Hello world", "optionsAsync() received unexpected data");
    }

    /** Convenience function that simply does a HTTP TRACE on the
        specified URL. 

        Example:
        ----
auto res = Http.trace("http://www.digitalmars.com");
writeln(res.toString());
        ----
     
        Returns:
        A $(XREF _curl, Result) object.
    */
    static Result trace(in const(char)[] url) {
        auto client = Http(url);
        Result res;
        client.method = Method.trace;
        client.onReceive = (ubyte[] data) { res._bytes ~= data; };
        client.onReceiveHeader = (const(char)[] key,const(char)[] value) { res.addHeader(key, value); };
        client.onReceiveStatusLine = (StatusLine l) { res.reset(); res.statusLine = l; };
        client.maxRedirects = Http.defaultMaxRedirects;
        client.perform;
        return res;
    }

    unittest {
        if (!netAllowed) return;
        assert(Http.trace(testUrl2).toString()[0..11] == "Hello world", "trace() received incorrect data");
    }

    /** Asynchronous version of trace(). 
        See_Also: getAsync() 
    */
    static AsyncResult traceAsync(string url) {
        return AsyncResult(url, "", "", Method.get);
    }

    unittest {
        if (!netAllowed) return;
        auto res = Http.getAsync(testUrl1);
        auto byline = res.byLine();
        assert(byline.front[0..11] == "Hello world", "getAsync() returns unexpected text");
	//        assert(Http.traceAsync(testUrl1).byLine().front[0..11] == "Hello world", "traceAsync() received unexpected data");
    }

    /** Convenience function that simply does a HTTP CONNECT on the
        specified URL. 

        Example:
        ----
auto res = Http.connect("http://www.digitalmars.com");
writeln(res.toString());
        ----

        Returns:
        A $(XREF _curl, Result) object.
    */
    static Result connect(in const(char)[] url) {
        auto client = Http(url);
        Result res;
        client.method = Method.connect;
        client.onReceive = (ubyte[] data) { res._bytes ~= data; };
        client.onReceiveHeader = (const(char)[] key,const(char)[] value) { res.addHeader(key, value); };
        client.onReceiveStatusLine = (StatusLine l) { res.reset(); res.statusLine = l; };
        client.maxRedirects = Http.defaultMaxRedirects;
        client.perform;
        return res;
    }

    unittest {
        // Disabled since google appengine does not support this method
        if (true ||!netAllowed) return;
        assert(Http.connect(testUrl2).toString()[0..11] == "Hello world", "connect() received incorrect data");
    }

    /** Specifying data to post when not using the onSend callback.

        The data is NOT copied by the library.  Content-Type will
        default to application/octet-stream.  Data is not converted or
        encoded for you.

        Example:
        ----
Http http = Http("http://www.mydomain.com");
http.onReceive = (ubyte[] data) { writeln(data); };
http.postData = [1,2,3,4,5];
http.perform;
        ----
    */
    @property ref Http postData(in const(void)[] data) {
        // cannot use callback when specifying data directly so we disable it here.
        curl.clear(CurlOption.readfunction); 
        addHeader("Content-Type: application/octet-stream");
        curl.set(CurlOption.postfields, cast(void*)data.ptr);
        return this;
    }
 
    /** Specifying data to post when not using the onSend callback.

        The data is NOT copied by the library.  Content-Type will
        default to application/octet-stream.  Data is not converted or
        encoded for you.

        Example:
        ----
Http http = Http("http://www.mydomain.com");
http.onReceive = (ubyte[] data) { writeln(data); };
http.postData = "The quick....";
http.perform;
        ----
    */
    @property ref Http postData(in const(char)[] data) {
        // cannot use callback when specifying data directly so we disable it here.
        curl.clear(CurlOption.readfunction); 
        curl.set(CurlOption.postfields, cast(void*)data.ptr);
        return this;
    }

    /**
       Set the event handler that receives incoming headers.

       Params:
       callback = the callback that recieves the key/value head strings.
       Make sure the callback copies the incoming params if
       it needs to store it because they are references into
       the backend and may very likely change.
       Example:
       ----
Http http = Http("http://www.google.com");
http.onReceive = (ubyte[] data) { writeln(data); };
http.onReceiveHeader = (const(char)[] key, const(char[]) value) { writeln(key, " = ", value); };
http.perform;
       ----
    
       See $(XREF curl, Curl.onReceiveHeader)
    */
    @property ref Http onReceiveHeader(void delegate(const(char)[],const(char)[]) callback) {
        // Wrap incoming callback in order to separate http status line from http headers.
        // On redirected requests there may be several such status lines. The last one is
        // the one recorded.
        auto dg = (const(char)[] header) { 
            if (header.length == 0) {
                // header delimiter
                return;
            }
            if (header[0..5] == "HTTP/") {
                auto m = match(header, regex(r"^HTTP/(\d+)\.(\d+) (\d+) (.*)$"));
                if (m.empty) {
                    // Invalid status line
                } else {
                    status.majorVersion = to!ushort(m.captures[1]);
                    status.minorVersion = to!ushort(m.captures[2]);
                    status.code = to!ushort(m.captures[3]);
                    status.reason = m.captures[4].idup;
                    if (_onReceiveStatusLine != null) {
                        _onReceiveStatusLine(status);
                    }
                }
                return;
            }

            // Normal http header
            auto m = match(cast(char[]) header, regex("(.*?): (.*)$"));

            if (!m.empty) {
                callback(m.captures[1].tolower, m.captures[2]); 
            }
     
        };
        curl.onReceiveHeader(callback is null ? null : dg);
        return this;
    }

    /**
    
     */
    @property ref Http onReceiveStatusLine(void delegate(StatusLine) callback) {
        _onReceiveStatusLine = callback;
        return this;
    }

    /**
       See $(LREF Curl.onSend)
    */
    @property ref Http onSend(size_t delegate(void[]) callback) {
        curl.clear(CurlOption.postfields); // cannot specify data when using callback
        curl.onSend(callback);
        return this;
    }

    /**
       The content length in bytes when using request that has content e.g. POST/PUT
       and not using chunked transfer. Is set as the "Content-Length" header.
    */
    @property void contentLength(size_t len) {

        CurlOption lenOpt;

        // Force post if necessary
        if (method != Method.put && method != Method.post)
            method = Method.post;

        if (method == Method.put)  {
            lenOpt = CurlOption.infilesize_large;
        } else { 
            // post
            lenOpt = CurlOption.postfieldsize_large;
        }

        if (len == 0) {
            // HTTP 1.1 supports requests with no length header set.
            addHeader("Transfer-Encoding: chunked");
            addHeader("Expect: 100-continue");
        } else {
            curl.set(lenOpt, len);      
        }
    }

    /**
       Perform a http request
    */
    void perform() {

        status.reset;

        if (headerChunk != null)
            curl.set(CurlOption.httpheader, headerChunk);

        switch (method) {
        case Method.head:
            curl.set(CurlOption.nobody, 1L);
            break;
        case Method.get:
            curl.set(CurlOption.httpget, 1L);
            break;
        case Method.post:
            curl.set(CurlOption.post, 1L);
            break;
        case Method.put:
            curl.set(CurlOption.upload, 1L);
            break;
        case Method.del:
            curl.set(CurlOption.customrequest, "DELETE");
            break;
        case Method.options:
            curl.set(CurlOption.customrequest, "OPTIONS");
            break;
        case Method.trace:
            curl.set(CurlOption.customrequest, "TRACE");
            break;
        case Method.connect:
            curl.set(CurlOption.customrequest, "CONNECT");
            break;
        }

        curl.perform;
    }

    /**
       Authentication method as specified in $(XREF etc.c.curl, AuthMethod).
    */
    @property void authenticationMethod(CurlAuth authMethod) {
        curl.set(CurlOption.httpauth, cast(long) authMethod);
    }

    /**
       Set max allowed redirections using the location header. 
       uint.max for infinite.
    */
    @property void maxRedirects(uint maxRedirs) {
        if (maxRedirs == uint.max) {
            // Disable
            curl.set(CurlOption.followlocation, 0);
        } else {
            curl.set(CurlOption.followlocation, 1);
            curl.set(CurlOption.maxredirs, maxRedirs);
        }
    }

    /** The standard HTTP methods 
     *  See_Also: http://www.w3.org/Protocols/rfc2616/rfc2616-sec5.html#sec5.1.1
     */
    enum Method {
        head, /// ditto
        get,  /// ditto
        post, /// ditto
        put,  /// ditto
        del,  /// ditto
        options, /// ditto
        trace,   /// ditto
        connect  /// ditto
    }

    /**
       HTTP status line ie. the first line returned in a HTTP response.
    
       If authentication or redirections are done then the status will be
       for the last response received.
    */
    struct StatusLine {
        ushort majorVersion; /// Major HTTP version ie. 1 in HTTP/1.0
        ushort minorVersion; /// Minor HTTP version ie. 0 in HTTP/1.0
        ushort code;         /// HTTP status line code e.g. 200
        string reason;       /// HTTP status line reason string
        
        /// Reset this status line
        void reset() { 
            majorVersion = 0;
            minorVersion = 0;
            code = 0;
            reason = "";
        }
    }
        
    /**
       The http result of a synchronous request.
    */
    struct Result {
            
        StatusLine statusLine;  /// The http status line
        private ubyte[] _bytes; /// The received http content as raw ubyte[]
        private string[string] _headers; /// The received http headers
        
        private void reset() {
            statusLine.reset();
            _bytes.length = 0;
            foreach(k; _headers.keys) _headers.remove(k);
        }
        
        /**
           The received headers. 
        */
        @property string[string] headers() {
            return _headers;
        }

        /**
	   Received content.
        */
        @property ubyte[] bytes() {
            return _bytes;
        }
        
        /**
           The received http content decoded from content-type charset into text.
        */
        @property Char[] toString(Char = char)() {
            auto scheme = encodingScheme;
            if (!scheme) {
                return null;
            }

            static if (is (Char == char))
                // Special case where encoding is utf8 since that is what
                // this method returns
                if (scheme.toString() == "UTF-8")
                    return cast(char[])(_bytes);

            auto r = decodeString!Char(_bytes, scheme);
            return r[1];
        }

        /**
           The encoding scheme name.
        */
        @property const(char)[] encodingSchemeName() {
            string * v = ("content-type" in headers);
            char[] charset = "ISO-8859-1".dup; // Default charset defined in HTTP RFC
            if (v) {
                auto m = match(cast(char[]) (*v), regex(".*charset=([^;]*)"));
                if (!m.empty && m.captures.length > 1) {
                    charset = m.captures[1];
                }
            }
            return charset;
        }

        /**
           The encoding scheme.
        */
        @property EncodingScheme encodingScheme() {
            return EncodingScheme.create(to!string(encodingSchemeName));
        }
      
        void addHeader(const(char)[] key, const(char)[] value) {
            string * v = (key in headers);
            if (v) {
                (*v) ~= value;
            } else {
                _headers[key] = to!string(value);
            }
        }

        /**
           Returns a range that will synchronously read the incoming
           http data by chunks of a given size.
    
           Example:
           ---
foreach (chunk; Http.get("http://www.google.com").byChunk(100)) 
    writeln("syncChunk: ", chunk);
           ---

           Params:
           chunkSize = The size of each chunk to be read. The last one is allowed to be smaller.

           Returns:
           An HttpChunkInputRange
        */
        auto byChunk(size_t chunkSize) {


            static struct HttpChunkInputRange {

                alias ubyte[] ChunkType;
                private size_t chunkSize;
                private ChunkType _bytes;
                private size_t len;
                private size_t offset;

                this(ubyte[] bytes, size_t chunkSize) {
                    this._bytes = bytes;
                    this.len = _bytes.length;
                    this.chunkSize = chunkSize;
                }

                @property auto empty() {
                    return offset == len;
                }
                
                @property ChunkType front() {
                    size_t nextOffset = offset + chunkSize;
                    if (nextOffset > len) nextOffset = len;
                    return _bytes[offset..nextOffset];
                }
                
                void popFront() {
                    offset = offset + chunkSize;
                    if (offset > len) offset = len;
                }
            }
            return HttpChunkInputRange(_bytes, chunkSize);
        }

        /**
           Returns a range that will synchronously read the incoming http data by line.
    
           Example:
           ---
// Read string
foreach (l; Http.get("http://www.google.com").byLine()) 
    writeln("syncLine: ", l);
           ---

           Params:
           keepTerminator = If the terminator for the lines should be included in the line returned
           terminator     = The terminating char for a line

           Returns:
           An HttpLineInputRange
        */
        auto byLine(Terminator = char, Char = char)(bool keepTerminator = false, 
                                                    Terminator terminator = '\x0a') {
            
            // This range is using algorithm splitter and could be
            // optimized by not using that. 
            static struct HttpLineInputRange {

                private Char[] lines;
                private Char[] current;
                private bool currentValid;
                private bool keepTerminator;
                private Terminator terminator;
                
                this(Char[] lines, bool kt, Terminator terminator) {
                    this.lines = lines;
                    this.keepTerminator = kt;
                    this.terminator = terminator;
                    currentValid = true;
                    popFront();
                }

                @property bool empty() {
                    return !currentValid;
                }
                
                @property Char[] front() {
                    enforce(currentValid, "Cannot call front() on empty range");
                    return current;
                }
                
                void popFront() {
                    enforce(currentValid, "Cannot call popFront() on empty range");
                    if (lines.empty) {
                        currentValid = false;
                        return;
                    }

                    if (keepTerminator) {
                        auto r = findSplitAfter(lines, [ terminator ]);
                        if (r[0].empty) {
                            current = r[1];
                            lines = r[0];
                        } else {
                            current = r[0];
                            lines = r[1];
                        }
                    } else {
                        auto r = findSplit(lines, [ terminator ]);
                        current = r[0];
                        lines = r[2];
                    }
                }
            }
            return HttpLineInputRange(toString!Char()[0..$], keepTerminator, terminator);
        }
    }

    /// Result struct used for asyncronous results
    struct AsyncResult {

        private enum RunState {
            init,
            running,
            statusReady,
            done
        }
        private RunState _running; 
        private Http.StatusLine _statusLine;
        private string[string] _headers;     // The received http headers
        private size_t _defaultStringBufferSize; 

        string _url;
        immutable(void)[] _postData;
        string _contentType;
        Method _httpMethod;

        this(string url, immutable(void)[] postData, 
             string contentType, Method httpMethod) {
            _url = url;
            _postData = postData;
            _contentType = contentType;
            _httpMethod = httpMethod;
            _running = RunState.init;
	    // A guess on how long a normal line is
	    _defaultStringBufferSize = 100;
        }
        
        /** The running state. */
        @property pure bool isRunning() {
            return _running == RunState.running || _running == RunState.statusReady;
        }
        
        /** The http status code.  
            This property is only valid after calling either byChunk or byLine 
        */
        @property Http.StatusLine statusLine() {
            enforce(_running == RunState.statusReady || _running == RunState.done,
                    "Cannot get statusLine before a call to either byChunk or byLine on a Http.AsyncResult");
            return _statusLine;
        }

        /** The http headers. 
            This property is only valid after calling either byChunk or byLine
         */
        @property string[string] headers() {
            enforce(_running == RunState.statusReady || _running == RunState.done, 
                    "Cannot get headers before a call to either byChunk or byLine on a Http.AsyncResult");
            return _headers;
        }

        /**
           The encoding scheme name.
           This property is only valid after calling either byChunk or byLine           
        */
        @property const(char)[] encodingSchemeName() {
            enforce(_running == RunState.statusReady || _running == RunState.done, 
                    "Cannot get encodingSchemeName before a call to either byChunk or byLine on a Http.AsyncResult");
            string * v = ("content-type" in headers);
            char[] charset = "ISO-8859-1".dup; // Default charset defined in HTTP RFC
            if (v) {
                auto m = match(cast(char[]) (*v), regex(".*charset=([^;]*)"));
                if (!m.empty && m.captures.length > 1) {
                    charset = m.captures[1];
                }
            }
            return charset;
        }

        /**
           The encoding scheme.
           This property is only valid after calling either byChunk or byLine           
        */
        @property EncodingScheme encodingScheme() {
            return EncodingScheme.create(to!string(encodingSchemeName));
        }

        /**
           Returns a range that will asyncronously read the incoming http data by chunks of a given size.
    
           Example:
           ---
// Read ubyte[] in chunks of 1000
foreach (l; Http.getAsync("http://www.google.com").byChunk(1000)) 
writeln("asyncChunk: ", l);
           ---

           Params:
           chunkSize = The size of each chunk to be read. The last one is allowed to be smaller.
           transmitBuffers = number of buffers filled asynchronously 

           Returns:
           An AsyncHttpChunkInputRange
        */
        auto byChunk(size_t chunkSize, size_t transmitBuffers = 5) {
            static struct AsyncHttpChunkInputRange {

                private AsyncResult * parent;
                private Tid workerTid;
                private ubyte[] chunk;
    
                this(AsyncResult * parent, Tid tid, size_t chunkSize, size_t transmitBuffers) {
                    this.parent = parent;
                    this.parent._running = RunState.running;
                    workerTid = tid;
                    state = State.needUnits;
                    
                    // Send buffers to other thread for it to use.
                    // Since no mechanism is in place for moving ownership
                    // we simply cast to immutable here and cast it back
                    // to mutable in the receiving end.
                    foreach (i ; 0..transmitBuffers) {
                        ubyte[] arr;
                        arr.length = chunkSize;
                        workerTid.send(cast(immutable(ubyte)[])arr);
                    }
                }

                mixin WorkerThreadProtocol!(ubyte, chunk);
            }

            // 50 is just an arbitrary number for now
            // TODO: fix setMaxMailboxSize(thisTid, 50, OnCrowding.block);
            Tid tid = spawn(&(_spawnAsyncRequest!ubyte), _url, _postData, _contentType, _httpMethod);
            tid.send(thisTid);
            return AsyncHttpChunkInputRange(&this, tid, chunkSize, transmitBuffers);
        }

        /**
           Returns a range that will asyncronously read the incoming http data by line.
    
           Example:
           ---
// Read char[] lines
foreach (l; Http.getAsync("http://www.google.com").byLine()) 
writeln("asyncLine: ", l);
           ---

           Params:
           keepTerminator = If the terminator for the lines should be included in the line returned
           terminator = The terminating char for a line
           transmitBuffers = number of buffers filled asynchronously 

           Returns:
           An AsyncHttpLineInputRange
        */
	  auto byLine(Terminator = char, Char = char)(bool keepTerminator = false, 
						      Terminator terminator = '\x0a',
                                                      size_t transmitBuffers = 5) {            
            static struct AsyncHttpLineInputRange {

                private AsyncResult * parent;
                private Tid workerTid;
                private bool keepTerminator;
                private Terminator terminator;
                private Char[] line;

                this(AsyncResult * parent, Tid tid, size_t transmitBuffers) {
                    this.parent = parent;
                    this.parent._running = RunState.running;
                    workerTid = tid;
                    state = State.needUnits;

                    // Send buffers to other thread for it to use.
                    // Since no mechanism is in place for moving ownership
                    // we simply cast to immutable here and cast it back
                    // to mutable in the receiving end.
                    foreach (i ; 0..transmitBuffers) {
                        Char[] arr;
                        arr.length = parent._defaultStringBufferSize;
                        workerTid.send(cast(immutable(Char)[])arr);
                    }
                }

                mixin WorkerThreadProtocol!(Char, line);
            }

            // 50 is just an arbitrary number for now
            // TODO: fix setMaxMailboxSize(thisTid, 50, OnCrowding.block);
            Tid tid = spawn(&_spawnAsyncRequest!(Char, Terminator),_url, _postData, _contentType, _httpMethod);
            tid.send(thisTid);
            tid.send(terminator);
            tid.send(keepTerminator);
            return AsyncHttpLineInputRange(&this, tid, transmitBuffers);
        }

        template WorkerThreadProtocol(Unit, alias units) {

            ~this() {
                workerTid.send(true);
            }

            @property auto empty() {
                tryEnsureUnits();
                return state == State.done;
            }
                
            @property Unit[] front() {
                tryEnsureUnits();
                assert(state == State.gotUnits, "Expected " ~ to!string(State.gotUnits) ~ " but got " ~ to!string(state));
                return units;
            }
                
            void popFront() {
                tryEnsureUnits();
                assert(state == State.gotUnits, "Expected " ~ to!string(State.gotUnits) ~ " but got " ~ to!string(state));
                state = State.needUnits;
                // Send to worker thread for buffer reuse
                workerTid.send(cast(immutable(Unit)[]) units);
                units = null;
            }

            enum State {
                needUnits,
                gotUnits,
                done
            }
            State state;

            private void tryEnsureUnits() {
                while (true) {
                    switch (state) {
                    case State.needUnits:
                        if (parent._running == RunState.done) {
                            state = State.done;
                            break;
                        }
                        receive(
                                (Tid origin, Message!(immutable(Unit)[]) _data) { 
                                    if (origin != workerTid)
                                        return false;
                                    units = cast(Unit[]) _data.data;
                                    state = State.gotUnits;
                                    return true;
                                },
                                (Tid origin, Message!(Tuple!(string,string)) header) {
                                    if (origin != workerTid)
                                        return false;
                                    parent._headers[header.data[0]] = header.data[1];
                                    return true;
                                },
                                (Tid origin, Message!(Http.StatusLine) l) {
                                    if (origin != workerTid)
                                        return false;
                                    parent._running = RunState.statusReady;
                                    parent._statusLine = l.data;
                                    return true;
                                },
                                (Tid origin, Message!bool f) { 
                                    if (origin != workerTid)
                                        return false;
				    state = state.done; 
				    parent._running = RunState.done; 
                                    return true;
				}
                                );
                        break;
                    case State.gotUnits: return;
                    case State.done:
                        return;
                    }
                }
            }

        } // WorkerThreadProtocol
    } // AsyncResult
} // Http

 
/*
   Ftp client functionality
*/
struct Ftp {
    
    mixin Protocol;

    /**
       Ftp access to the specified url
    */
    this(in const(char)[] url) {
        curl = Curl(true);
        curl.set(CurlOption.url, url);
    }

    /** Convenience function that simply does a FTP GET on specified
        URL. Internally this is implemented using an instance of the
        Ftp class.

        Example:
        ----
Ftp.get("ftp://ftp.digitalmars.com/sieve.ds", "/tmp/downloaded-file");
        ----

        Params:
        url = The URL of the FTP
    */
    static void get(in const(char)[] url, in string saveToPath) {
        auto client = new Ftp(url);
        auto f = new std.stream.File(saveToPath, FileMode.OutNew);
        client.onReceive = (ubyte[] data) { f.write(data); };
        client.perform;
        f.close;
    }

    /**
       Performs the ftp request as it has been configured
    */
    void perform() {
        curl.perform;
    }

}

/// An exception class for curl
class CurlException: Exception {
    /// Construct a CurlException with given error message.
    this(string msg) { super(msg); }
}

unittest {
    
    if (!netAllowed) return;
    
    // GET with custom data receivers 
    Http http = Http("http://www.google.com");
    http.onReceiveHeader = (const(char)[] key, const(char)[] value) { writeln(key ~ ": " ~ value); };
    http.onReceive = (ubyte[] data) { /* drop */ };
    http.perform;
    
    // POST with timouts
    http.url("http://d-programming-language.appspot.com/testUrl2");
    http.onReceive = (ubyte[] data) { writeln(data); };
    http.connectTimeout(dur!"seconds"(10));
    http.dataTimeout(dur!"seconds"(10));  
    http.dnsTimeout(dur!"seconds"(10));
    http.postData = "The quick....";
    http.perform;
    
    // PUT with data senders 
    string msg = "Hello world";
    http.onSend = delegate size_t(void[] data) { 
        if (!msg.length) return 0; 
        auto m = cast(void[])msg;
        auto l = m.length;
        data[0..l] = m[0..$];  
        msg.length = 0;
        return l;
    };
    http.method = Http.Method.put; // defaults to POST
    // Defaults to chunked transfer if not specified. We don't want that now.
    http.contentLength = 11; 
    http.perform;
    
    // FTP
    Ftp.get("ftp://ftp.digitalmars.com/sieve.ds", "./downloaded-file");
    
    http.method = Http.Method.get;
    http.url = "http://upload.wikimedia.org/wikipedia/commons/5/53/Wikipedia-logo-en-big.png";
    http.onReceive = delegate(ubyte[]) { };
    http.onProgress = (double dltotal, double dlnow, double ultotal, double ulnow) {
        writeln("Progress ", dltotal, ", ", dlnow, ", ", ultotal, ", ", ulnow);
        return 0;
    };
    http.perform;
    
    foreach (chunk; Http.getAsync("http://www.google.com").byChunk(100)) {
        stdout.rawWrite(chunk);
    }
    /*
    foreach (chunk; Http.get("http://www.google.com").async.byChunk(100)) {
        stdout.rawWrite(chunk);
    }
    foreach (chunk; Http.get("http://www.google.com").auth("login", "pw").timeout(100).async.byChunk(100)) {
        stdout.rawWrite(chunk);
    }    
    */
}

version (unittest) {

  private auto netAllowed() {
      return getenv("PHOBOS_TEST_ALLOW_NET") != null;
  }
  
}