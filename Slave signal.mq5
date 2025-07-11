//+------------------------------------------------------------------+
//|                                                     SignalClient |
//|                       programming & development - Alexey Sergeev |
//+------------------------------------------------------------------+
#property copyright "© 2006-2016 Alexey Sergeev"
#property link      "profy.mql@gmail.com"
#property version   "1.00"

#include <SocketLib.mqh>
#include <Trade\Trade.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\PositionInfo.mqh>
CTrade Trade;

input string Host="127.0.0.1";
input ushort Port=8081;

SOCKET64 client = INVALID_SOCKET64;
string msg = "";

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    EventSetTimer(0.5); 
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) 
{ 
    EventKillTimer(); 
    CloseClean(); 
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTick()
{
    if(client == INVALID_SOCKET64) 
        StartClient(Host, Port);
    else
    {
        uchar data[];
        if(Receive(data) > 0)
        {
            msg += CharArrayToString(data);
            printf("received msg from server: %s", msg);
        }
        CheckMessage();
    }
    Sleep(500);
}

//+------------------------------------------------------------------+
//| Start client connection                                          |
//+------------------------------------------------------------------+
void StartClient(string addr, ushort port)
{
    int res = 0;
    char wsaData[]; 
    ArrayResize(wsaData, sizeof(WSAData));
    res = WSAStartup(MAKEWORD(2,2), wsaData);
    if (res != 0) 
    { 
        Print("-WSAStartup failed error: " + string(res)); 
        return; 
    }

    client = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if(client == INVALID_SOCKET64) 
    { 
        Print("-Create failed error: " + WSAErrorDescript(WSAGetLastError())); 
        CloseClean(); 
        return; 
    }

    char ch[]; 
    StringToCharArray(addr, ch);
    sockaddr_in addrin;
    addrin.sin_family = AF_INET;
    addrin.sin_addr.u.S_addr = inet_addr(ch);
    addrin.sin_port = htons(port);

    ref_sockaddr_in ref;
    ref.in = addrin;

    res = connect(client, ref.ref, sizeof(sockaddr_in));
    if(res == SOCKET_ERROR)
    {
        int err = WSAGetLastError();
        if(err != WSAEISCONN) 
        { 
            Print("-Connect failed error: " + WSAErrorDescript(err)); 
            CloseClean(); 
            return; 
        }
    }

    int non_block = 1;
    res = ioctlsocket(client, FIONBIO, non_block);
    if(res != NO_ERROR) 
    { 
        Print("ioctlsocket failed error: " + string(res)); 
        CloseClean(); 
        return; 
    }

    Print("connect OK");
}

//+------------------------------------------------------------------+
//| Receive data from socket                                         |
//+------------------------------------------------------------------+
int Receive(uchar &rdata[])
{
    if(client == INVALID_SOCKET64) 
        return 0;

    char rbuf[512]; 
    int rlen = 512; 
    int r = 0, res = 0;
    
    do
    {
        res = recv(client, rbuf, rlen, 0);
        if(res < 0)
        {
            int err = WSAGetLastError();
            if(err != WSAEWOULDBLOCK) 
            { 
                Print("-Receive failed error: " + string(err) + " " + WSAErrorDescript(err)); 
                CloseClean(); 
                return -1; 
            }
            break;
        }
        if(res == 0 && r == 0) 
        { 
            Print("-Receive. connection closed"); 
            CloseClean(); 
            return -1; 
        }
        r += res; 
        ArrayCopy(rdata, rbuf, ArraySize(rdata), 0, res);
    }
    while(res > 0 && res >= rlen);
    
    return r;
}

//+------------------------------------------------------------------+
//| Close socket connection                                          |
//+------------------------------------------------------------------+
void CloseClean()
{
    if(client != INVALID_SOCKET64)
    {
        if(shutdown(client, SD_BOTH) == SOCKET_ERROR) 
            Print("-Shutdown failed error: " + WSAErrorDescript(WSAGetLastError()));
        closesocket(client); 
        client = INVALID_SOCKET64;
    }

    WSACleanup();
    Print("close socket");
}

//+------------------------------------------------------------------+
//| Check incoming messages                                          |
//+------------------------------------------------------------------+
void CheckMessage()
{
    string signal;
    while(FindNextSignal(signal)) 
    { 
        printf("server signal: %s", signal); 
        ProcessSignal(signal);
    }
}

//+------------------------------------------------------------------+
//| Process signal from master                                       |
//+------------------------------------------------------------------+
void ProcessSignal(string signal)
{
    string res[]; 
    int parts = StringSplit(signal, '|', res);
    
    if(parts < 2) 
    { 
        printf("-wrong signal format: %s", signal); 
        return; 
    }
    
    string action = res[0];
    
    if(action == "OPEN" && parts == 4)
    {
        string symbol = res[1];
        double lot = NormalizeDouble(StringToDouble(res[2]), 2);
        long magic = StringToInteger(res[3]); // Already converted magic number
        
        // Check if we already have this position
        if(!HasPositionWithMagic(symbol, magic))
        {
            OpenPosition(symbol, lot, magic);
        }
        else
        {
            printf("Position with magic %d already exists for %s", magic, symbol);
        }
    }
    else if(action == "CLOSE" && parts == 3)
    {
        string symbol = res[1];
        long magic = StringToInteger(res[2]); // Already converted magic number
        
        ClosePositionByMagic(symbol, magic);
    }
    else
    {
        printf("-unknown signal format: %s", signal);
    }
}

//+------------------------------------------------------------------+
//| Check if position exists with magic number                      |
//+------------------------------------------------------------------+
bool HasPositionWithMagic(string symbol, long magic)
{
    int total = PositionsTotal();
    for(int i = 0; i < total; i++)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetString(POSITION_SYMBOL) == symbol && 
               PositionGetInteger(POSITION_MAGIC) == magic)
            {
                return true;
            }
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| Open position with master ticket as magic number                |
//+------------------------------------------------------------------+
void OpenPosition(string symbol, double lot, long magic)
{
    CTrade trade;
    trade.SetExpertMagicNumber((ulong)magic);
    
    bool result = false;
    
    if(lot > 0)
    {
        Print("Opening BUY: ", lot, " on ", symbol, " with magic: ", magic);
        result = trade.Buy(lot, symbol);
    }
    else if(lot < 0)
    {
        Print("Opening SELL: ", -lot, " on ", symbol, " with magic: ", magic);
        result = trade.Sell(-lot, symbol);
    }
    
    if(!result)
    {
        Print("Failed to open position: ", symbol, " lot: ", lot, " magic: ", magic);
        Print("Error: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
    }
    else
    {
        Print("Successfully opened position: ", symbol, " lot: ", lot, " magic: ", magic);
    }
}

//+------------------------------------------------------------------+
//| Close position by magic number                                   |
//+------------------------------------------------------------------+
void ClosePositionByMagic(string symbol, long magic)
{
    CTrade trade;
    bool found = false;
    
    int total = PositionsTotal();
    for(int i = total - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetString(POSITION_SYMBOL) == symbol && 
               PositionGetInteger(POSITION_MAGIC) == magic)
            {
                Print("Closing position: ", symbol, " magic: ", magic, " ticket: ", ticket);
                
                if(trade.PositionClose(ticket))
                {
                    Print("Successfully closed position: ", ticket);
                    found = true;
                }
                else
                {
                    Print("Failed to close position: ", ticket);
                    Print("Error: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
                }
            }
        }
    }
    
    if(!found)
    {
        printf("No position found to close: %s magic: %d", symbol, magic);
    }
}

//+------------------------------------------------------------------+
//| Find next signal in message                                      |
//+------------------------------------------------------------------+
bool FindNextSignal(string &signal)
{
    int b = StringFind(msg, "<<"); 
    if(b < 0) 
        return false;
        
    int e = StringFind(msg, ">>"); 
    if(e < 0) 
        return false;

    signal = StringSubstr(msg, b + 2, e - b - 2);
    msg = StringSubstr(msg, e + 2);
    return true;
}