                                                       {

  Copyright (c) 2017, Daniel Mecklenburg Jr.
  All rights reserved.

  Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that the following conditions are met:

  * Redistributions of source code must retain the above copyright notice, this
    list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright notice,
    this list of conditions and the following disclaimer in the documentation
    and/or other materials provided with the distribution.

  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
  DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
  FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
  DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
  SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
  CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
  OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
  OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


  VTX Server
  2017-08-04
  vtxserv.pas

}

program vtxserv;

{ mini todo:
  	client:
	    hotspots
    	zmodem xfer
      highlight / copy to clipboard
}

{$codepage utf8}
{$mode objfpc}{$H+}
{$apptype console}

{ $define DEBUG}

uses
  cmem,
  {$IFDEF UNIX}{$IFDEF UseCThreads}
    cthreads,
  {$ENDIF}{$ENDIF}

  // pascal / os stuff
  {$IFDEF WINDOWS}
    Windows, winsock2,
  {$ENDIF}
  Classes, Process, Pipes, DateUtils, SysUtils,
  IniFiles, Crt, LConvEncoding, Variants,

  // network stuff
  sockets, BlckSock, Synautil,
  WebSocket2, CustomServer2;

{$define BUFFSIZE:=16768}

{ *************************************************************************** }
{ TYPES }
{$region TYPES }
type

  TvtxWSConnection =  class;

  // status update prototype for threads
  TvtxProgressEvent = procedure(ip, msg: string) of object;

  { Node process type. }
  TvtxNodeType = ( ExtProc, Telnet );

  { TvtxSystemInfo : Board Inofo record }
  TvtxSystemInfo = record
    // [server] info
    SystemName :      string;   // name of bbs - webpage title.
    SystemIP :        string;   // ip address of this host - needed to bind to socket.
    InternetIP :      string;   // ip address as seen from internet.
    HTTPPort :        string;   // port number for http front end.
    WSPort :          string;   // port number for ws/wss back end.
    WSSecure :				boolean;	// use wss instead of ws?
    MaxConnections :  integer;
    AutoConnect :			boolean;

    // [client] info
    NodeType :        TvtxNodeType;
    ExtProc :         string;		// string to launch node process
    TelnetIP :        string; 	// connection info for internal telnet client
    TelnetPort :      string;
    Terminal :				string;		// ANSI, PETSCII
    CodePage :				string;		// CP437, PETSCII64, etc
    Columns :					integer;	// columns for term console.
    Rows :						integer;	// -1 = history
    History :					integer;	// max rows before scrolled to dev/nul
    XScale :					real;			// scale everything by this on the X axis.
    Initialize :			string;		// terminal init string
    PageAttr :				longint;
    CrsrAttr :				longint;
    CellAttr :				longint;
  end;

  // available net services
  TServices = ( HTTP, WS, All, Unknown );
  TServSet = set of TServices;

  { TvtxNodeProcess : thread for spawning connection console. terminate
    connection on exit }
  TvtxNodeProcess = class(TThread)
    private
      fProgress :   string;
      fProgressIP :	string;
      fOnProgress : TvtxProgressEvent;
      procedure     DoProgress;

    protected
      procedure     Execute; override;
      procedure     PipeToConn;
      procedure     PipeToLocal;
      function      Negotiate(buf : array of byte; len : integer) : rawbytestring;
      function      SendBuffer(buf : pbyte; len : integer) : integer;

    public
      serverCon :   TvtxWSConnection;
//      Handshaking :	boolean;
      constructor   Create(CreateSuspended: boolean);
      destructor    Destroy; override;
      property      OnProgress: TvtxProgressEvent read fOnProgress write fOnProgress;
  end;

  { TvtxWSServer : websocket server class object }
  TvtxWSServer = class(TWebSocketServer)
    public
      function GetWebSocketConnectionClass(
                Socket: TTCPCustomConnectionSocket;
                Header: TStringList;
                ResourceName, sHost, sPort, Origin, Cookie: string;
            out HttpResult: integer;
            var Protocol, Extensions: string) : TWebSocketServerConnections; override;
  end;

  { TvtxWSConnection : Websocket connection class. }
  TvtxWSConnection = class(TWebSocketServerConnection)
    public
      ExtProcType : TvtxNodeType;

      // needed for ExtProc
      ExtNode :     TvtxNodeProcess;  // the TThread that runs below ExtProcess
      ExtProc :     TProcess;         // the TProcess spawned board

      tnsock :      longint;
      tnserver :    sockaddr_in;
      tnbuf :       array [0..BUFFSIZE] of byte;
      tnlive :      boolean;
      tnstate :     integer;          // telnet read state (IAC cmds)
      tncmd :       byte;             // current telnet command
      tnqus :       array [0..255] of byte;
      tnqhim :      array [0..255] of byte;

      property ReadFinal: boolean read fReadFinal;
      property ReadRes1: boolean read fReadRes1;
      property ReadRes2: boolean read fReadRes2;
      property ReadRes3: boolean read fReadRes3;
      property ReadCode: integer read fReadCode;
      property ReadStream: TMemoryStream read fReadStream;

      property WriteFinal: boolean read fWriteFinal;
      property WriteRes1: boolean read fWriteRes1;
      property WriteRes2: boolean read fWriteRes2;
      property WriteRes3: boolean read fWriteRes3;
      property WriteCode: integer read fWriteCode;
      property WriteStream: TMemoryStream read fWriteStream;
  end;

  { TvtxApp : Main application class }
  TvtxApp = class
    procedure StartHTTP;
    procedure StartWS;
    procedure StopHTTP;
    procedure StopWS;
    procedure WriteCon(ip, msg : string); register;
    procedure WSBeforeAddConnection(Server : TCustomServer; aConnection : TCustomConnection;var CanAdd : boolean); register;
    procedure WSAfterAddConnection(Server : TCustomServer; aConnection : TCustomConnection); register;
    procedure WSBeforeRemoveConnection(Server : TCustomServer; aConnection : TCustomConnection); register;
    procedure WSAfterRemoveConnection(Server : TCustomServer; aConnection : TCustomConnection); register;
    procedure WSSocketError(Server: TCustomServer; Socket: TTCPBlockSocket); register;
    procedure WSOpen(aSender: TWebSocketCustomConnection);
    procedure WSRead(aSender : TWebSocketCustomConnection; aFinal, aRes1, aRes2, aRes3 : boolean; aCode :integer; aData :TMemoryStream);
    procedure WSWrite(aSender : TWebSocketCustomConnection; aFinal, aRes1, aRes2, aRes3 : boolean; aCode :integer; aData :TMemoryStream);
    procedure WSClose(aSender: TWebSocketCustomConnection; aCloseCode: integer; aCloseReason: string; aClosedByPeer: boolean);
    procedure WSTerminate(Sender : TObject); register;
    procedure CloseAllNodes;
    procedure CloseNode(n : integer);
    procedure NodeTerminate(Sender: TObject);
    procedure HTTPTerminate(Sender : TObject); register;
  end;

  { TvtxHTTPServer : for basic webserver front end for dishing out client }
  TvtxHTTPServer = class(TThread)
    private
      fProgress :   string;
      fProgressIP :	string;
      fOnProgress : TvtxProgressEvent;
      procedure     DoProgress;

    protected
      procedure     Execute; override;
      procedure     AttendConnection(ASocket : TTCPBlockSocket);
      function      SendText(
                      ASocket : TTCPBlockSocket;
                      ContentType : string;
                      Filename : string) : integer;
      function      SendBinary(
                      ASocket : TTCPBlockSocket;
                      ContentType : string;
                      Filename : string) : integer;
      function 			SendString(
                			ASocket : TTCPBlockSocket;
                			ContentType : string;
                			Data : string) : integer;
      function 			SendTextRaw(
                			ASocket : TTCPBlockSocket;
                			ContentType : string;
                			Filename : string) : integer;

    public
      constructor   Create(CreateSuspended: boolean);
      destructor    Destroy; override;
      property      OnProgress : TvtxProgressEvent
                      read fOnProgress
                      write fOnProgress;
  end;
{$endregion}

{ *************************************************************************** }
{ CONSTANTS }
{$region CONSTANTS}
const
  // names of net services
  ProcessType : array [0..1] of string = ('ExtProc', 'Telnet' );

  CRLF = #13#10;

{$endregion}

{ *************************************************************************** }
{ GLOBALS }
{$region GLOBALS}
var
  app :           TvtxApp;				// main app class
  SystemInfo :    TvtxSystemInfo;	// system about this vtx
  lastaction :    TDateTime;      // last time activity for hibernation
  serverWS :      TvtxWSServer;   // ws server.
  serverHTTP :    TvtxHTTPServer; // http srever.
  runningWS :     boolean;
  runningHTTP :   boolean;
  cmdbuff :       string = '';    // console linein buffer
  logout :				Text;						// server logfile.
{$endregion}

{ *************************************************************************** }
{ SUPPORT PROCEDURES / FUNCTIONS }
{$region SUPPORT ROUTINES}

{ Get a socket error description. }
function GetSocketErrorMsg(errno : integer) : string;
begin
  result := 'Unknown error.';
  case errno of
    6:  result := 'Specified event object handle is invalid.';
    8:  result := 'Insufficient memory available.';
    87: result := 'One or more parameters are invalid.';
    995:  result := 'Overlapped operation aborted.';
    996:  result := 'Overlapped I/O event object not in signaled state.';
    997:  result := 'Overlapped operations will complete later.';
    10004:  result := 'Interrupted function call.';
    10009:  result := 'File handle is not valid.';
    10013:  result := 'Permission denied.';
    10014:  result := 'Bad address.';
    10022:  result := 'Invalid argument.';
    10024:  result := 'Too many open files.';
    10035:  result := 'Resource temporarily unavailable.';
    10036:  result := 'Operation now in progress.';
    10037:  result := 'Operation already in progress.';
    10038:  result := 'Socket operation on nonsocket.';
    10039:  result := 'Destination address required.';
    10040:  result := 'Message too long.';
    10041:  result := 'Protocol wrong type for socket.';
    10042:  result := 'Bad protocol option.';
    10043:  result := 'Protocol not supported.';
    10044:  result := 'Socket type not supported.';
    10045:  result := 'Operation not supported.';
    10046:  result := 'Protocol family not supported.';
    10047:  result := 'Address family not supported by protocol family.';
    10048:  result := 'Address already in use.';
    10049:  result := 'Cannot assign requested address.';
    10050:  result := 'Network is down.';
    10051:  result := 'Network is unreachable.';
    10052:  result := 'Network dropped connection on reset.';
    10053:  result := 'Software caused connection abort.';
    10054:  result := 'Connection reset by peer.';
    10055:  result := 'No buffer space available.';
    10056:  result := 'Socket is already connected.';
    10057:  result := 'Socket is not connected.';
    10058:  result := 'Cannot send after socket shutdown.';
    10059:  result := 'Too many references.';
    10060:  result := 'Connection timed out.';
    10061:  result := 'Connection refused.';
    10062:  result := 'Cannot translate name.';
    10063:  result := 'Name too long.';
    10064:  result := 'Host is down.';
    10065:  result := 'No route to host.';
    10066:  result := 'Directory not empty.';
    10067:  result := 'Too many processes.';
    10068:  result := 'User quota exceeded.';
    10069:  result := 'Disk quota exceeded.';
    10070:  result := 'Stale file handle reference.';
    10071:  result := 'Item is remote.';
    10091:  result := 'Network subsystem is unavailable.';
    10092:  result := 'Winsock.dll version out of range.';
    10093:  result := 'Successful WSAStartup not yet performed.';
    10101:  result := 'Graceful shutdown in progress.';
    10102:  result := 'No more results.';
    10103:  result := 'Call has been canceled.';
    10104:  result := 'Procedure call table is invalid.';
    10105:  result := 'Service provider is invalid.';
    10106:  result := 'Service provider failed to initialize.';
    10107:  result := 'System call failure.';
    10108:  result := 'Service not found.';
    10109:  result := 'Class type not found.';
    10110:  result := 'No more results.';
    10111:  result := 'Call was canceled.';
    10112:  result := 'Database query was refused.';
    11001:  result := 'Host not found.';
    11002:  result := 'Nonauthoritative host not found.';
    11003:  result := 'This is a nonrecoverable error.';
    11004:  result := 'Valid name, no data record of requested type.';
    11005:  result := 'QoS receivers.';
    11006:  result := 'QoS senders.';
    11007:  result := 'No QoS senders.';
    11008:  result := 'QoS no receivers.';
    11009:  result := 'QoS request confirmed.';
    11010:  result := 'QoS admission error.';
    11011:  result := 'QoS policy failure.';
    11012:  result := 'QoS bad style.';
    11013:  result := 'QoS bad object.';
    11014:  result := 'QoS traffic control error.';
    11015:  result := 'QoS generic error.';
    11016:  result := 'QoS service type error.';
    11017:  result := 'QoS flowspec error.';
    11018:  result := 'Invalid QoS provider buffer.';
    11019:  result := 'Invalid QoS filter style.';
    11020:  result := 'Invalid QoS filter type.';
    11021:  result := 'Incorrect QoS filter count.';
    11022:  result := 'Invalid QoS object length.';
    11023:  result := 'Incorrect QoS flow count.';
    11024:  result := 'Unrecognized QoS object.';
    11025:  result := 'Invalid QoS policy object.';
    11026:  result := 'Invalid QoS flow descriptor.';
    11027:  result := 'Invalid QoS provider-specific flowspec.';
    11028:  result := 'Invalid QoS provider-specific filterspec.';
    11029:  result := 'Invalid QoS shape discard mode object.';
    11030:  result := 'Invalid QoS shaping rate object.';
    11031:  result := 'Reserved policy QoS element type.';
  end
end;

function InList(str : string; list : array of string) : integer;
var
  i : integer;
begin
  result := -1;
  for i := 0 to length(list) - 1 do
    if upCase(str) = upCase(list[i]) then
    begin
      result := i;
      break;
    end;
end;

function GetIP(strName : string) : string;
var
  phe : pHostEnt;
begin
  //Convert the name to a cstring since 'gethostbyname' expects a cstring
  phe := gethostbyname(pchar(strName));
  if phe = nil then
  	result := '0.0.0.0'
  else
	begin
		result := format('%d.%d.%d.%d', [
    	byte(phe^.h_addr^[0]),
    	byte(phe^.h_addr^[1]),
    	byte(phe^.h_addr^[2]),
    	byte(phe^.h_addr^[3])]);
  end;
 end;

{ Create javascript values object for client }
function ClientValues : string;
var
  strout : string;
  wsproto : string;
  autocon : string;

begin

  // websocket proxy type
	wsproto := 'ws://';
	if SystemInfo.WSSecure then
  	wsproto := 'wss://';

  autocon := '0';
  if SystemInfo.AutoConnect then
  	autocon := '1';

  if SystemInfo.NodeType = Telnet then
  begin

    // config for telnet
  	strout :=
        'var vtxdata = {'  + CRLF
    	+ '  sysName:     "' + SystemInfo.SystemName + '",' + CRLF
    	+ '  wsConnect:   "' + wsproto + SystemInfo.InternetIP + ':' + SystemInfo.WSPort + '",' + CRLF
      + '  term:        "' + SystemInfo.Terminal + '",' + CRLF
      + '  codePage:    "' + SystemInfo.CodePage + '",' + CRLF
      + '  crtCols:     ' + IntToStr(SystemInfo.Columns) + ',' + CRLF
      + '  crtRows:     ' + IntToStr(SystemInfo.Rows) + ',' + CRLF
      + '  crtHistory:  ' + IntToStr(SystemInfo.History) + ',' + CRLF
      + '  xScale:      ' + FloatToStr(SystemInfo.XScale) + ',' + CRLF
  		+ '  initStr:     "' + SystemInfo.Initialize + '",' + CRLF
      + '  defPageAttr: 0x' + inttohex(SystemInfo.PageAttr, 4) + ',' + CRLF
      + '  defCrsrAttr: 0x' + inttohex(SystemInfo.CrsrAttr, 4) + ',' + CRLF
      + '  defCellAttr: 0x' + inttohex(SystemInfo.CellAttr, 4) + ',' + CRLF
      + '  autoConnect: ' + autocon + ',' + CRLF
      + '  telnet:      1' + CRLF
      + '};' + CRLF;
  end
  else
  begin
    // config for extproc
  	strout :=
        'var vtxdata = {'  + CRLF
    	+ '  sysName:     "' + SystemInfo.SystemName + '",' + CRLF
    	+ '  wsConnect:   "' + wsproto + SystemInfo.InternetIP + ':' + SystemInfo.WSPort + '",' + CRLF
      + '  term:        "' + SystemInfo.Terminal + '",' + CRLF
      + '  codePage:    "' + SystemInfo.CodePage + '",' + CRLF
      + '  crtCols:     ' + IntToStr(SystemInfo.Columns) + ',' + CRLF
      + '  crtRows:     ' + IntToStr(SystemInfo.Rows) + ',' + CRLF
      + '  crtHistory:  ' + IntToStr(SystemInfo.History) + ',' + CRLF
      + '  xScale:      ' + FloatToStr(SystemInfo.XScale) + ',' + CRLF
  		+ '  initStr:     "' + SystemInfo.Initialize + '",' + CRLF
      + '  defPageAttr: 0x' + inttohex(SystemInfo.PageAttr, 4) + ',' + CRLF
      + '  defCrsrAttr: 0x' + inttohex(SystemInfo.CrsrAttr, 4) + ',' + CRLF
      + '  defCellAttr: 0x' + inttohex(SystemInfo.CellAttr, 4) + ',' + CRLF
      + '  autoConnect: ' + autocon + ',' + CRLF
      + '  telnet:      0' + CRLF
      + '};' + CRLF;
  end;

  result := strout;
end;

{ read the vtxserv.ini file for settings }
procedure LoadSettings;
var
  iin : 				TIniFile;
	v1, v2, v3 : 	integer;

const
  server = 'Server';
  client = 'Client';

  crsrSizes : array [0..3] of string = ( 'None', 'Thin', 'Thick', 'Full' );
  crsrOrientations : array [0..1] of string = ( 'Horz', 'Vert' );

begin
  iin := TIniFile.Create('vtxserv.ini');

  // [server] info
  SystemInfo.SystemName :=  iin.ReadString(server, 'SystemName',  'A VTX Board');
  SystemInfo.SystemIP :=    iin.ReadString(server, 'SystemIP',    'localhost');
  SystemInfo.InternetIP :=  iin.ReadString(server, 'InternetIP',  'localhost');
  SystemInfo.HTTPPort :=    iin.ReadString(server, 'HTTPPort',    '7001');
  SystemInfo.WSPort :=      iin.ReadString(server, 'WSPort',      '7003');
  SystemInfo.WSSecure :=		iin.ReadBool(server, 	 'WSSecure', 		false);
  SystemInfo.AutoConnect :=	iin.ReadBool(server, 	 'AutoConnect', false);
  SystemInfo.MaxConnections := iin.ReadInteger(server, 'MaxConnections',  32);
  SystemInfo.NodeType :=    TvtxNodeType(InList(
                              iin.ReadString(server, 'NodeType', 	'ExtProc'),
                              ProcessType));
  // [client] info
  SystemInfo.ExtProc :=     iin.ReadString(client, 'ExtProc',     'vtxtest.exe @UserIP@');
  SystemInfo.TelnetIP :=    iin.ReadString(client, 'TelnetIP', 		'localhost');
  SystemInfo.TelnetPort :=  iin.ReadString(client, 'TelnetPort',  '7002');

  SystemInfo.Terminal :=		iin.ReadString(client, 'Terminal',		'ANSI');
  SystemInfo.CodePage :=    iin.ReadString(client, 'CodePage', 		'UTF8');

  SystemInfo.Columns :=			iin.ReadInteger(client, 'Columns', 		80);
  SystemInfo.Rows :=				iin.ReadInteger(client, 'Rows', 			-1);
  SystemInfo.History :=			iin.ReadInteger(client, 'History', 		500);
  SystemInfo.XScale :=			iin.ReadFloat(client, 	'XScale', 1.0);

  SystemInfo.Initialize :=	iin.ReadString(client, 'Initialize',	'\x1B[0m');

  // pageattr
  v1 :=	iin.ReadInteger(client, 'PageColor', 		0);
  v2 :=	iin.ReadInteger(client, 'BorderColor', 	0);
	SystemInfo.PageAttr :=
  	(v1 and $FF) or
    ((v2 and $FF) shl 8);

  // cursorattr
  v1 :=	InList(iin.ReadString(client, 'CursorSize', 'Thick'), crsrSizes);
  v2 :=	InList(iin.ReadString(client, 'CursorOrientation', 'Horz'), crsrOrientations);
  v3 :=	iin.ReadInteger(client, 'CursorColor', 	7);
	SystemInfo.CrsrAttr :=
  	(v3 and $FF) or
    ((v1 and $3) shl 8) or
    ((v2 and $1) shl 10);

	// cellattr
  v1 :=	iin.ReadInteger(client, 'CharColor', 7);
  v2 :=	iin.ReadInteger(client, 'CharBackground', 0);
  SystemInfo.CellAttr :=
		(v1 and $FF) or
  	((v2 and $FF) shl 8);

  // resolve possible named IPs to IP addresses.
	SystemInfo.SystemIP := GetIP(SystemInfo.SystemIP);
	SystemInfo.InternetIP := GetIP(SystemInfo.InternetIP);
	SystemInfo.TelnetIP := GetIP(SystemInfo.TelnetIP);

  iin.Free;
end;

{ get services associated with words in list 1 .. end }
function GetServFromWords(word : TStringArray) : TServSet;
var
  i : integer;

begin
  result := [];
  for i := 1 to Length(word) - 1 do
  begin
    case upcase(word[i]) of
      'HTTP':   result += [ HTTP ];
      'WS':     result += [ WS ];
      'ALL' :   result += [ All ];
      else      result += [ Unknown ];
    end;
  end;
end;

{ read a console line, returns '' if none entered }
function ConsoleLineIn : string;
var
  key :     char;

begin
  result := '';
  if wherex = 1 then
    write(']' + cmdbuff);
  if keypressed then
  begin
    lastaction := now;
    key := readkey;
    if key <> #0 then
    begin
      case key of
        #13:
          begin
            write(CRLF);
            result := cmdbuff;
            cmdbuff := '';
          end;

        #8: // backspace
          begin
            if length(cmdbuff) > 0 then
            begin
              write(#8' '#8);
              cmdbuff := LeftStr(cmdbuff, cmdbuff.length - 1);
            end;
          end;
        else
          begin
            write(key);
            cmdbuff += key;
          end;
      end;
    end
    else
    begin
      // special key
      key := readkey;
      case ord(key) of
        $4B:  // left arrow
          begin
            if length(cmdbuff) > 0 then
            begin
              write(#8' '#8);
              cmdbuff := LeftStr(cmdbuff, cmdbuff.length - 1);
            end;
          end;
        else  beep;
      end;
    end;
  end;
end;

{ replace @codes@ with system values }
function ReplaceAtCodes(str : string) : string;
begin
  str := str.Replace('@SystemName@', SystemInfo.SystemName);
  str := str.Replace('@SystemIP@', SystemInfo.SystemIP);
  str := str.Replace('@InternetIP@', SystemInfo.InternetIP);
  str := str.Replace('@HTTPPort@', SystemInfo.HTTPPort);
  str := str.Replace('@TelnetIP@', SystemInfo.TelnetIP);
  str := str.Replace('@TelnetPort@', SystemInfo.TelnetPort);
  str := str.Replace('@WSPort@', SystemInfo.WSPort);
  str := str.Replace('@CodePage@', SystemInfo.CodePage);
  str := str.Replace('@Columns@', IntToStr(SystemInfo.Columns));
  str := str.Replace('@XScale@', FloatToStr(SystemInfo.XScale));
  str := str.Replace('@Terminal@', SystemInfo.Terminal);
  str := str.Replace('@Initialize@', SystemInfo.Initialize);
  result := str;
end;

{$endregion}

{ *************************************************************************** }
{ TvtxHTTPServer }

constructor TvtxHTTPServer.Create(CreateSuspended: boolean);
begin
  fProgress := '';
  fProgressIP := '';
  FreeOnTerminate := True;
  inherited Create(CreateSuspended);
end;

destructor TvtxHTTPServer.Destroy;
begin
  inherited Destroy;
end;

procedure TvtxHTTPServer.DoProgress;
begin
  if Assigned(FOnProgress) then
  begin
    FOnProgress(fProgressIP, fProgress);
  end;
end;

// main http listener loop
procedure TvtxHTTPServer.Execute;
var
  ListenerSocket,
  ConnectionSocket: TTCPBlockSocket;
  errno : integer;
begin
  begin
    ListenerSocket := TTCPBlockSocket.Create;
    ConnectionSocket := TTCPBlockSocket.Create;
    // not designed to run on high performance production servers
    // give users all the time they need.
    try
      ListenerSocket.CreateSocket;
      ListenerSocket.SetTimeout(10000);
      ListenerSocket.SetLinger(true, 10000);
      ListenerSocket.Bind(SystemInfo.SystemIP, SystemInfo.HTTPPort);
      ListenerSocket.Listen;
    finally
      repeat
        if ListenerSocket.CanRead(1000) then
        begin
          lastaction := now;  // there are active connections
          // todo: thread this out.
          ConnectionSocket.Socket := ListenerSocket.Accept;
          errno := ConnectionSocket.LastError;
          if errno <> 0 then
          begin
            fProgressIP := GetSocketErrorMsg(errno);
            fProgress := Format('** Error HTTP accepting socket. #%d',[ errno ]);
            Synchronize(@DoProgress);
          end
          else
          begin
            AttendConnection(ConnectionSocket);
            ConnectionSocket.CloseSocket;
          end;
        end;
        if Terminated then
          break;
      until false;
    end;
    ListenerSocket.Free;
    ConnectionSocket.Free;
  end;
end;




// send an binary file from www directory
function TvtxHTTPServer.SendBinary(
          ASocket : TTCPBlockSocket;
          ContentType : string;
          Filename : string) : integer;
var
  fin : TFileStream;
  size : integer;
  buff : pbyte;
  expires : TTimeStamp;
  begin
  result := 200;
  Filename := 'www' + Filename;
  if FileExists(Filename) then
  begin
    expires := DateTimeToTimeStamp(now);
    expires.Date += 30;  // + 30 days
      fin := TFileStream.Create(Filename, fmShareDenyNone);
    size := fin.Size;
    buff := getmemory(fin.Size);
    fin.ReadBuffer(buff^, Size);
    fin.Free;
      try
      ASocket.SendString(
          'HTTP/1.0 200' + CRLF
        + 'Pragma: public' + CRLF
        + 'Cache-Control: max-age=86400' + CRLF
        + 'Expires: ' + Rfc822DateTime(TimeStampToDateTime(expires)) + CRLF
        + 'Content-Type: ' + ContentType + CRLF
        + '' + CRLF);
      ASocket.SendBuffer(buff, size);
    except
      fProgressIP := '';
      fProgress:='** Error on HTTPServer.SendBinary.';
      Synchronize(@DoProgress);
    end;
    freememory(buff);
  end
  else
    result := 404;
end;

// send text file from www directory
// swap @ codes in text files.
function TvtxHTTPServer.SendText(
          ASocket : TTCPBlockSocket;
          ContentType : string;
          Filename : string) : integer;
var
  fin : TextFile;
  instr, str : string;

begin
  result := 200;
  Filename := 'www' + Filename;
  if FileExists(Filename) then
  begin
    assignfile(fin, Filename);
    reset(fin);
    str := '';
    while not eof(fin) do
    begin
      readln(fin, instr);
			instr := ReplaceAtCodes(instr);
      instr := instr.Replace('@UserIP@', ASocket.GetRemoteSinIP);
      str += instr + CRLF;
    end;
    closefile(fin);
    try
      ASocket.SendString(
          'HTTP/1.0 200' + CRLF
        + 'Content-Type: ' + ContentType + CRLF
        + 'Content-Length: ' + IntToStr(length(str)) + CRLF
        + 'Connection: close' + CRLF
        + 'Date: ' + Rfc822DateTime(now) + CRLF
        + 'Server: VTX Mark-II' + CRLF + CRLF
        + '' + CRLF);
      ASocket.SendString(str);
    except
      fProgressIP := '';
      fProgress := '** Error on HTTPServer.SendTextFile';
      Synchronize(@DoProgress);
    end;
  end
  else
    result := 404;
end;

// send an binary file from www directory
function TvtxHTTPServer.SendTextRaw(
          ASocket : TTCPBlockSocket;
          ContentType : string;
          Filename : string) : integer;
var
  fin : TFileStream;
  size : integer;
  buff : pbyte;
  expires : TTimeStamp;
  begin
  result := 200;
  Filename := 'www' + Filename;
  if FileExists(Filename) then
  begin
    expires := DateTimeToTimeStamp(now);
    expires.Date += 30;  // + 30 days
      fin := TFileStream.Create(Filename, fmShareDenyNone);
    size := fin.Size;
    buff := getmemory(fin.Size);
    fin.ReadBuffer(buff^, Size);
    fin.Free;
      try
      ASocket.SendString(
      		'HTTP/1.0 200' + CRLF
    		+ 'Content-Type: ' + ContentType + CRLF
		    + 'Content-Length: ' + IntToStr(size) + CRLF
    		+ 'Connection: close' + CRLF
		    + 'Date: ' + Rfc822DateTime(now) + CRLF
		    + 'Server: VTX Mark-II' + CRLF + CRLF
    		+ '' + CRLF);
      ASocket.SendBuffer(buff, size);
    except
      fProgressIP := '';
      fProgress:='** Error on HTTPServer.SendTextRaw.';
      Synchronize(@DoProgress);
    end;
    freememory(buff);
  end
  else
    result := 404;
end;

// send text file from www directory
// swap @ codes in text files.
function TvtxHTTPServer.SendString(
          ASocket : TTCPBlockSocket;
          ContentType : string;
          Data : string) : integer;
begin
  result := 200;

  try
    ASocket.SendString(
        'HTTP/1.0 200' + CRLF
      + 'Content-Type: ' + ContentType + CRLF
      + 'Content-Length: ' + IntToStr(length(Data)) + CRLF
      + 'Connection: close' + CRLF
      + 'Date: ' + Rfc822DateTime(now) + CRLF
      + 'Server: VTX Mark-II' + CRLF + CRLF
      + '' + CRLF);
    ASocket.SendString(Data);
  except
    fProgressIP := '';
    fProgress := '** Error on HTTPServer.SendTextFile';
    Synchronize(@DoProgress);
    result := 404;
  end;
end;

// fulfill the request.
procedure TvtxHTTPServer.AttendConnection(ASocket: TTCPBlockSocket);
var
  timeout :   integer;
  code :      integer;
  s:          string;
  ext:        string;
  //method :    string;
  uri :       string;
  //protocol :  string;

begin
  timeout := 120000;

  //read request line
  s := ASocket.RecvString(timeout);
  fetch(s, ' '); //method := fetch(s, ' ');
  uri := fetch(s, ' ');
  fetch(s, ' '); //protocol := fetch(s, ' ');

  //read request headers
  repeat
    s := ASocket.RecvString(Timeout);
  until s = '';

  code := 200;
  if uri = '/' then
    code := SendText(ASocket, 'text/html', '/index.html')
  else if uri = '/vtxdata.js' then
  begin
		code := SendString(ASocket, 'text/javascript', ClientValues);
  end
  else
  begin
    ext := ExtractFileExt(uri);
    case ext of
      // todo - load from list.
      '.css':   code := SendText(ASocket, 'text/css', uri);
      '.js':    code := SendText(ASocket, 'text/javascript', uri);
      '.png':   code := SendBinary(ASocket, 'image/png', uri);
      '.ico':		code := SendBinary(ASocket, 'image/x-icon', uri);
      '.eot':   code := SendBinary(ASocket, 'application/vnd.ms-fontobject', uri);
      '.svg':   code := SendBinary(ASocket, 'image/svg+xml', uri);
      '.svgz':  code := SendBinary(ASocket, 'image/svg+xml', uri);
      '.ttf':   code := SendBinary(ASocket, 'application/font-sfnt', uri);
      '.woff':  code := SendBinary(ASocket, 'application/font-woff', uri);
      '.ogg':   code := SendBinary(ASocket, 'audio/ogg', uri);
      '.wav':   code := SendBinary(ASocket, 'audio/vnd.wav', uri);
      '.mp3':   code := SendBinary(ASocket, 'audio/mpeg', uri);
      '.txt':		code := SendTextRaw(ASocket, 'text/css', uri);
      // add others here as needed
      else      code := 404;
    end;
  end;
    if code <> 200 then
      ASocket.SendString(
        'HTTP/1.0 ' + IntToStr(code) + CRLF
        + httpCode(code) + CRLF);
end;


{ *************************************************************************** }
{ TvtxNodeProcess }

// copy input to websocket
procedure TvtxNodeProcess.PipeToConn;
  var
    i, bytes : integer;
    b : byte;
    str : ansistring;
begin

  str := '';
  try
    bytes := serverCon.ExtProc.Output.NumBytesAvailable;
  except
    bytes := 0;
  end;

  if bytes > 0 then
  begin
    lastaction := now;
    for i := 0 to bytes - 1 do
    begin
      try
        b := serverCon.ExtProc.Output.ReadByte;
      finally
        str += char(b);
      end;
    end;
    //serverCon.SendText(str);
    serverCon.SendBinary(TStringStream.Create(str));
  end;
end;

// copy input to console
procedure TvtxNodeProcess.PipeToLocal;
var
  i, bytes : integer;
  b : byte;
  str : ansistring;

begin
  try
    bytes := serverCon.ExtProc.StdErr.NumBytesAvailable;
  except
    bytes := 0;
  end;

  str := '';
  if bytes > 0 then
  begin
    lastaction := now;
    for i := 0 to bytes - 1 do
    begin
      try
        b := serverCon.ExtProc.StdErr.ReadByte;
      finally
        str += char(b);
      end;
    end;
    fProgress := str;
    Synchronize(@DoProgress);
  end;
end;

// thread launched that launches tprocess and waits for it to terminate.
// closes clients connection at end.
constructor TvtxNodeProcess.Create(CreateSuspended: boolean);
begin
  fProgressIP := '';
  fProgress := '';
  FreeOnTerminate := True;
//  Handshaking := false;
  inherited Create(CreateSuspended);
end;

destructor TvtxNodeProcess.Destroy;
begin
  inherited Destroy;
end;

procedure TvtxNodeProcess.DoProgress;
begin
  if Assigned(FOnProgress) then
  begin
    FOnProgress(fProgressIP, fProgress);
  end;
end;

(*
function BufferDump(buf : pbyte; len : integer) : string;
var
  i : integer;
  str : string;
begin
  str := '';
  for i := 0 to len-1 do
  	str += ' ' + IntToHex(buf[i], 2);
  result := str.substring(1);
end;


function BufferDump(strin : rawbytestring) : string;
var
  i : integer;
  str : string;
begin
  str := '';
  for i := 1 to length(strin) do
  	str += ' ' + IntToHex(byte(strin[i]), 2);
  result := str.substring(1);
end;
*)

// send data to node process
function TvtxNodeProcess.SendBuffer(buf : pbyte; len : longint) : integer;
begin
  result := -1;
  case SystemInfo.NodeType of

    ExtProc:
      begin
	   		if (serverCon.ExtProc <> nil) and serverCon.ExtProc.Running then
		  		result := serverCon.ExtProc.Input.Write(buf[0], len);
      end;

    Telnet:
			begin
	  	  if serverCon.tnlive then
        begin
  	  	  result := fpsend(serverCon.tnsock, buf, len, 0);
				end;
      end;
  end;
end;

// process str for telnet commands, return string with commands stripped.
function TvtxNodeProcess.Negotiate(
    buf : array of byte;
    len : integer) : rawbytestring;
var
  strout : rawbytestring;
  b : 			byte;
  i : 			integer;

begin
  strout := '';
  for i := 0 to len - 1 do
  begin
    b := byte(buf[i]);
    strout := strout + char(b);
  end;
  result := strout;
end;

// node process thread. launch extproc process or do a telnet session.
procedure TvtxNodeProcess.Execute;
var
  parms :   TStringArray;
  i :       integer;
  he :      PHostEnt;
  status :  integer;
  rv :      integer;
  linger :  TLinger;
  str :     rawbytestring;
  mode :    longint;

begin
  // for each connect that has process, send input, read output
  fProgressIP := serverCon.Socket.GetRemoteSinIP;
  if serverWS <> nil then
  begin
    case SystemInfo.NodeType of

	    ExtProc:
        begin
          // execute a spawned node session.
          fProgress := 'Spawning process.';
          Synchronize(@DoProgress);

          parms := SystemInfo.ExtProc.Split(' ');
          for i := 0 to length(parms) - 1 do
            parms[i] := ReplaceAtCodes(parms[i]);
          parms[i] := parms[i].Replace('@UserIP@', serverCon.Socket.GetRemoteSinIP);

          serverCon.ExtProc := TProcess.Create(nil);
          serverCon.ExtProc.CurrentDirectory:= 'node';
          serverCon.ExtProc.FreeOnRelease;
          serverCon.ExtProc.Executable := 'node\' + parms[0];
          for i := 1 to length(parms) - 1 do
            serverCon.ExtProc.Parameters.Add(parms[i]);

          serverCon.ExtProc.Options := [
              //poWaitOnExit,
              poUsePipes,
              poNoConsole,
              poDefaultErrorMode,
              poNewProcessGroup
            ];

          // go run. wait on exit.
          try
            serverCon.ExtProc.Execute;

            while not serverCon.IsTerminated and serverCon.ExtProc.Running do
            begin
              // pipe strout to websocket.
              if serverCon.ExtProc.Output <> nil then
                PipeToConn;

              // pipe strerr to local console.
              if serverCon.ExtProc.Stderr <> nil then
                PipeToLocal;

            end;

          except
            fProgress := '** Error on Node Process. ExtProc type.';
            Synchronize(@DoProgress);
          end;
        end;

	    Telnet:
        begin
          // execute a telnet node session.

          // create socket
          serverCon.tnlive := false;
          serverCon.tnsock := fpsocket(AF_INET, SOCK_STREAM, 0);
          if serverCon.tnsock = -1 then
          begin
            fProgress := 'Unable to create telnet client socket.';
            Synchronize(@DoProgress);
            exit;
          end;

          // build address
          ZeroMemory(@serverCon.tnserver, sizeof(sizeof(TSockAddrIn)));
          he := gethostbyname(@(SystemInfo.TelnetIP[1]));
          if he = nil then
          begin
            fProgress := 'Unable to resolve telnet address.';
            Synchronize(@DoProgress);
            exit;
          end;
          serverCon.tnserver.sin_addr.S_addr := inet_addr(he^.h_name);
          serverCon.tnserver.sin_family := AF_INET;
          serverCon.tnserver.sin_port := htons(StrToInt(SystemInfo.TelnetPort));

          // connect
          status := fpconnect(
                      serverCon.tnsock,
                      @serverCon.tnserver,
                      sizeof(TSockAddrIn));
          if status < 0 then
          begin
            fProgress := 'Unable to connect to telnet server.';
            Synchronize(@DoProgress);
            exit;
          end;
          serverCon.tnlive := true;

          // linger set to 1 sec.
          linger.l_linger := 1;
          linger.l_onoff := 1;
          setsockopt(
            serverCon.tnsock,
            SOL_SOCKET,
            SO_LINGER,
            @linger,
            sizeof(TLinger));

          // set non-blocking mode
          mode := 1;
          ioctlsocket(serverCon.tnsock, longint(FIONBIO), @mode);

          // connected!!! loop
          while true do
          begin

            if serverCon.tnsock = -1 then
            begin
              fProgress := 'Invalid socket.';
              Synchronize(@DoProgress);
              break;
            end;

            // stuff to read
            rv := fprecv(serverCon.tnsock, @serverCon.tnbuf, BUFFSIZE, 0);
            if rv = 0 then
            begin
              fProgress := 'Telnet closed by remote.';
              Synchronize(@DoProgress);
              break;
            end
            else if rv < 0 then
            begin

             	// if not wouldblock, disconnect
              if WSAGetLastError <> WSAEWOULDBLOCK then
              begin
                fProgress := 'Telnet closed by remote.';
                Synchronize(@DoProgress);
                break;
              end;

            end;

            if not serverCon.Closed then
            begin
              if rv > 0 then
              begin
                // handle telnet negotiations
                str := negotiate(serverCon.tnbuf, rv);
                if length(str) > 0 then
                begin
                  serverCon.SendBinary(TStringStream.Create(str));
                end;
              end
            end
            else
            begin
              fProgress := 'Websocket closed during telnet.';
              Synchronize(@DoProgress);
              break;
            end;
          end;

          fpshutdown(serverCon.tnsock, 2);
          serverCon.tnlive := false;
          fProgress := 'Closed socket.';
          Synchronize(@DoProgress);
        end;
    end;

		// disconnect afterwards.
    if not serverCon.Closed then
    	serverCon.Close(wsCloseNormal, 'Good bye');

//    fProgress := 'Finished node process.';
//    Synchronize(@DoProgress);
  end;

  fProgress := 'Node Terminating.';
  Synchronize(@DoProgress);
end;


{ *************************************************************************** }
{ TvtxWSServer }

function TvtxWSServer.GetWebSocketConnectionClass(
          Socket: TTCPCustomConnectionSocket;
          Header: TStringList;
          ResourceName, sHost, sPort, Origin, Cookie: string;
      out HttpResult: integer;
      var Protocol, Extensions: string): TWebSocketServerConnections;
begin
  result := TvtxWSConnection;
end;


{ *************************************************************************** }
{ TvtxApp - main application stuffz }

procedure TvtxApp.HTTPTerminate(Sender : TObject); register;
begin
  WriteCon('', 'HTTP Terminated.');
end;

procedure TvtxApp.NodeTerminate(Sender: TObject);
begin
//  WriteCon('', 'Node Terminated.');
end;

procedure TvtxApp.WSBeforeAddConnection(
      Server :      TCustomServer;
      aConnection : TCustomConnection;
  var CanAdd :      boolean); register;
begin
//  WriteCon('', 'Before Add WS Connection.');
end;

procedure TvtxApp.WSAfterAddConnection(
      Server : TCustomServer;
      aConnection : TCustomConnection); register;
var
  con : TvtxWSConnection;
begin
  con := TvtxWSConnection(aConnection);

//  WriteCon(con.Socket.GetRemoteSinPort, 'WebSocket Connection.');

	con.OnOpen :=  @WSOpen;
  con.OnRead :=  @WSRead;
  con.OnWrite := @WSWrite;
  con.OnClose := @WSClose;

  // spawn a new process for this connection
  con.ExtNode := TvtxNodeProcess.Create(true);
  con.ExtNode.fProgressIP := aConnection.Socket.GetRemoteSinIP;
  con.ExtNode.serverCon := con;
  con.ExtNode.OnProgress := @WriteCon;
  con.ExtNode.OnTerminate := @NodeTerminate;
  try
    con.ExtNode.Start;
  except
    WriteCon('', '** Error on Node Create.');
  end;

end;

procedure TvtxApp.WSOpen(aSender: TWebSocketCustomConnection);
begin
  lastaction := now;
  WriteCon(aSender.Socket.GetRemoteSinIP, 'Open WS Connection.');
end;

// send wbsocket incoming data to process
procedure TvtxApp.WSRead(
      aSender : TWebSocketCustomConnection;
      aFinal,
      aRes1,
      aRes2,
      aRes3 :   boolean;
      aCode :   integer;
      aData :   TMemoryStream);
var
  bytes : longint;
  con :   TvtxWSConnection;
  buf :   array [0..2049] of byte;

//const
//  hsresp : string = #27'[?50;86;84;88c';

begin
  lastaction := now;
  //WriteCon('Read WS Connection.');

  con := TvtxWSConnection(aSender);

  bytes := aData.Size;
  if bytes > 2048 then
    bytes := 2048;

  if bytes > 0 then
  begin
    aData.ReadBuffer(buf[0], bytes);

    if con.ExtNode.SendBuffer(@buf, bytes) < 0 then
    begin
//      app.WriteCon(aSender.Socket.GetRemoteSinIP, 'Error sending to node process.');
//     	con.Close(wsCloseNormal, 'Good bye');
    end;
  end;
end;

procedure TvtxApp.WSWrite(
      aSender : TWebSocketCustomConnection;
      aFinal,
      aRes1,
      aRes2,
      aRes3 :   boolean;
      aCode :   integer;
      aData :   TMemoryStream);
begin
  lastaction := now;
  //WriteCon('Write WS Connection.');
end;

procedure TvtxApp.WSClose(
      aSender: TWebSocketCustomConnection;
      aCloseCode: integer;
      aCloseReason: string;
      aClosedByPeer: boolean);
begin
  WriteCon(aSender.Socket.GetRemoteSinIP, 'Close WS Connection.');
end;

procedure TvtxApp.WSBeforeRemoveConnection(
      Server :      TCustomServer;
      aConnection : TCustomConnection); register;
var
  con : TvtxWSConnection;
begin
  //WriteCon('', 'Before Remove WS Connection 1.');
  con := TvtxWSConnection(aConnection);

  case SystemInfo.NodeType of

    ExtProc:
      begin
        if (con.ExtProc <> nil) and con.ExtProc.Running then
        begin
          WriteCon(con.Socket.GetRemoteSinIP, 'Force Terminate Node Processes');
          try
            con.ExtProc.Terminate(0);
          except
            WriteCon('', '** Error terminating node process.');
          end;
        end;
      end;

    Telnet:
      if con.tnlive then
      begin
      	fpshutdown(con.tnsock, 4);
        con.tnlive := false;
      end;

  end;
  //WriteCon('', 'Before Remove WS Connection 2.');
end;

procedure TvtxApp.WSAfterRemoveConnection(
      Server : TCustomServer;
      aConnection : TCustomConnection); register;
begin
//  WriteCon(aConnection.Socket.GetRemoteSinIP, 'After Remove WS Connection.');
end;

procedure TvtxApp.WSSocketError(
      Server: TCustomServer;
      Socket: TTCPBlockSocket); register;
begin
  WriteCon(Socket.GetRemoteSinIP, 'WS Error : ' + Socket.LastErrorDesc + '.');
end;

procedure TvtxApp.WSTerminate(Sender : TObject); register;
begin
  WriteCon('', 'WS server Terminated.');
end;

procedure TvtxApp.WriteCon(ip, msg : string); register;
var
  ips : array of string;
begin
  write(#13);

  TextColor(LightCyan);
  write(#13);
  Write(
    format('%4.2d/%2.2d/%2.2d %2.2d:%2.2d:%2.2d ',
    [
      YearOf(now),    // year
      MonthOf(now),   // month
      DayOf(now),     // day
      HourOf(now),    // 24hr
      MinuteOf(now),  // min
      SecondOf(Now) // sec
    ]));

  if ip <> '' then
  begin
    ips := ip.split('.');
    TextColor(Yellow);
    Write(
      format('(%3.3d.%3.3d.%3.3d.%3.3d) ',
      [
        strtoint(ips[0]),
        strtoint(ips[1]),
        strtoint(ips[2]),
        strtoint(ips[3])
      ]));
  end;

  TextColor(LightGreen);
  writeln(msg);
end;

procedure TvtxApp.StartHTTP;
begin
  // start http server
  if not runningHTTP then
  begin
    WriteCon('', format('HTTP server starting on port %s.', [SystemInfo.HTTPPort]));
    serverHTTP := TvtxHTTPServer.Create(true);
    serverHTTP.OnProgress := @WriteCon;
    serverHTTP.OnTerminate := @HTTPTerminate;
    serverHTTP.Start;
    runningHTTP := true;
  end
  else
    WriteCon('', 'HTTP server already running.');
end;

procedure TvtxApp.StartWS;
begin
  // create websocket server
  if not runningWS then
  begin
    WriteCon('', format('WS server starting on port %s.', [SystemInfo.WSPort]));
    serverWS := TvtxWSServer.Create(SystemInfo.SystemIP, SystemInfo.WSPort);
    serverWS.FreeOnTerminate := true;
    serverWS.MaxConnectionsCount := SystemInfo.MaxConnections;
    serverWS.OnBeforeAddConnection := @WSBeforeAddConnection;
    serverWS.OnAfterAddConnection := @WSAfterAddConnection;
    serverWS.OnBeforeRemoveConnection := @WSBeforeRemoveConnection;
    serverWS.OnAfterRemoveConnection := @WSAfterRemoveConnection;
    serverWS.OnSocketError := @WSSocketError;
    serverWS.OnTerminate := @WSTerminate;
    serverWS.SSL := false;
    serverWS.Start;
    runningWS := true;
  end
  else
    WriteCon('', 'WS server already running.');
end;

procedure TvtxApp.StopHTTP;
begin
  if runningHTTP then
  begin
    WriteCon('', 'HTTP server terminating.');
    if serverHTTP <> nil then
      serverHTTP.Terminate;
    runningHTTP := false;
  end;
end;

{ Call CloseAllConnections prior to calling. }
procedure TvtxApp.StopWS;
begin
  if runningWS then
  begin
    WriteCon('', 'WS server terminating.');
    if serverWS <> nil then
      serverWS.Terminate;
    runningWS := false;
  end;
end;

{ Terminate all end all client node processes, close all connections }
procedure TvtxApp.CloseAllNodes;
var
  i : integer;
begin
  // terminate all node processes.
  if runningWS then
  begin
    i := serverWS.Count - 1;
    while i >= 0 do
    begin
      CloseNode(i);
      dec(i);
    end;
  end;
end;

procedure TvtxApp.CloseNode(n : integer);
var
  con : TvtxWSConnection;
begin
  if not serverWS.Connection[n].Finished then
  begin
    con := TvtxWSConnection(serverWS.Connection[n]);
    case SystemInfo.NodeType of

	    ExtProc:
  		  begin
      		if (con.ExtProc <> nil) and con.ExtProc.Running then
		        try
    		      con.ExtProc.Terminate(1);
		        finally
    		      WriteCon('', 'Node Process terminated.');
		        end;
		    end;

      Telnet:
        if con.tnlive then
        begin
        	fpshutdown(con.tnsock, 4);
          con.tnlive := false;
        end;

    end;
  end;
end;

{$R *.res}

{$region Main}
var
  linein :      string;
  word :        TStringArray;
  serv :        TServSet;
  Done :        boolean;
  Hybernate :   boolean;
  i :           integer;
  count :       integer;
  ThreadRan :   boolean;
  WsaData :     TWSAData;
  t1, t2 :			boolean;

const
  WSAVersion : integer = $0202;

begin

  {$IFDEF WINDOWS}
    SetConsoleOutputCP(CP_UTF8);
  {$ENDIF}

  assign(logout, 'vtxserv.log');
  if FileExists('vtxserv.log') then
	  append(logout)
  else
  	rewrite(logout);

  TextColor(LightGreen);
  write('VTX HTTP/WS Server Console.' + CRLF
  		+ 'Version 0.9' + CRLF
      + '2017 Dan Mecklenburg Jr.' + CRLF
      + CRLF
      + 'Type HELP for commands, QUIT to exit.' + CRLF + CRLF);

  app :=            TvtxApp.Create;
  serverWS :=       nil;
  runningHTTP :=    false;
  runningWS :=      false;
  Done :=           false;
  Hybernate :=      false;

  LoadSettings;

  if SystemInfo.NodeType = Telnet then
    WSAStartup(WSAVersion, WsaData);

  lastaction := now;

  linein := '';
  repeat
    linein := ConsoleLineIn;
    if linein <> '' then
    begin
      // parse command
        word := linein.Split(' ');
        case upcase(word[0]) of
        'START':  // start a servive.
            begin
              serv := GetServFromWords(word);
              if Unknown in serv then
                app.WriteCon('', 'Unknown service specified.')
              else if serv = [] then
                app.WriteCon('', 'No service specified.')
              else
              begin
                if All in serv then
                begin
                  app.StartHTTP;
                  app.StartWS;
                end
                else
                begin
                  if HTTP in serv then
                    app.StartHTTP;
                  if WS in serv then
                    app.StartWS;
                end;
              end;
            end;

        'STOP': // stop a service.
            begin
              serv := GetServFromWords(word);
              if Unknown in serv then
                app.WriteCon('', 'Unknown service specified.')
              else if serv = [] then
                app.WriteCon('', 'No service specified.')
              else
              begin
                if All in serv then
                begin
                  app.StopHTTP;
                  app.CloseAllNodes();
                  app.StopWS;
                end
                else
                begin
                  if HTTP in serv then
                    app.StopHTTP;
                  if WS in serv then
                  begin
                    app.CloseAllNodes();
                    app.StopWS;
                  end;
                end;
              end;
            end;

        'STATUS':
          begin
            linein := '';
            if runningHTTP    then linein += 'HTTP, ';
            if runningWS      then linein += 'WS, ';
            if linein = ''    then linein += 'None, ';
            linein := LeftStr(linein, linein.length - 2);
            app.WriteCon('', 'Currently running services: ' + linein);
            if runningWS then
             app.WriteCon('', 'Current WS connections: ' + inttostr(serverWS.Count));
          end;

        'QUIT':   Done := true;

        'CLS':    ClrScr;

        'LIST':   // list connection
          begin
            if runningWS then
            begin
              count := 0;
              for i := 0 to serverWS.Count - 1 do
              begin
                if not serverWS.Connection[i].IsTerminated then
                begin
                  app.WriteCon('', format('%d) %s', [
                    i + 1,
                    serverWS.Connection[i].Socket.GetRemoteSinIP ]));
                  inc(count);
                end;
              end;
              if count = 0 then
                app.WriteCon('', 'No active connections.');
            end
            else
              app.WriteCon('', 'WS service is not running.');
          end;

        'KICK':   // kick a connection
          begin
            if runningWS then
            begin
              if length(word) = 2 then
              begin
                i := strtoint(word[1]) - 1;
                if (i >= 0) and (i < serverWS.Count) then
                begin
                  if not serverWS.Connection[i].IsTerminated then
                  begin
                    app.CloseNode(i);
                  end
                  else
                  begin
                    app.WriteCon('', 'Connection already closed..');
                  end;
                end
                else
                  app.WriteCon('', 'No such connection.');
              end
              else
                app.WriteCon('', 'Specify a connection number. (See LIST)');
            end
            else
              app.WriteCon('', 'WS service is not running.');
          end;

        'LOADCFG':
          begin
            t1 := runningHttp;
            t2 := runningWS;
        		if runningHTTP then
            begin
            	app.StopHTTP;
              while not serverHTTP.Finished do;
						end;
            if runningWS then
            begin
	            app.CloseAllNodes();
        			app.StopWS;
              while not serverWS.Finished do;
            end;
            LoadSettings;
            sleep(2000);
            if t1 then
	            app.StartHTTP;
            if t2 then
            	app.StartWS;
          end;

        'HELP':
          begin
            app.WriteCon('', 'Commands: START <serv> [<serv> ..]  - Start one or more service.');
            app.WriteCon('', '          STOP <serv> [<serv> ..]  - Stop one or more service.');
            app.WriteCon('', '          STATUS  - Display what''s running.');
            app.WriteCon('', '          LIST  - List current WS connections.');
            app.WriteCon('', '          KICK <connum>  - Disconnect a WS connection.');
            app.WriteCon('', '          CLS  - Clear console screen.');
            app.WriteCon('', '          HELP  - You''re soaking in it.');
            app.WriteCon('', '          QUIT  - Stop all services and exit.');
            app.WriteCon('', '          LOADCFG - force reload config.');
            app.WriteCon('', '');
            app.WriteCon('', '          serv = HTTP, WS, or ALL');
          end
          else
            app.WriteCon('', 'Unknown command.');
      end;
    end;

    // tickle the threads.
    ThreadRan := CheckSynchronize;
    if ThreadRan then
    begin
      app.WriteCon('', 'A thread ran.');
    end;

    // hybernate mode?
    if SecondsBetween(now, lastaction) > 120 then
    begin
      if not Hybernate then
        app.WriteCon('', 'Hybernating.... zzz...');

      Hybernate := true;
      sleep(100);
    end
    else
    begin
      if Hybernate then
        app.WriteCon('', 'Waking up! O.O');

      Hybernate := false;
    end;

  until Done;

  app.CloseAllNodes;
  app.StopHTTP;
  app.StopWS;
  sleep(2000);

  if SystemInfo.NodeType = Telnet then
    WSACleanup;

	closefile(logout);
end.
{$endregion}

