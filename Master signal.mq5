//+------------------------------------------------------------------+
//| Convert ticket to magic number (handle overflow)                |
//+------------------------------------------------------------------+
long TicketToMagic(ulong ticket)
{
    // Simple hash to fit ulong ticket into long magic number
    // Use lower 31 bits to ensure positive magic number
    return (long)(ticket & 0x7FFFFFFF);
}

//+------------------------------------------------------------------+
//|                                                     Master       |
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

bool bChangeTrades;
uchar data[];
SOCKET64 server = INVALID_SOCKET64;
SOCKET64 conns[];

// Arrays to store previous positions data
ulong previousTickets[];
string previousSymbols[];
double previousVolumes[];
int previousTypes[];

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() 
{ 
    EventSetTimer(0.05); 
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
//| Trade event handler                                              |
//+------------------------------------------------------------------+
void OnTick()
{
if(server == INVALID_SOCKET64) 
        StartServer(Host, Port);
    else
    {
        AcceptClients();
        if(bChangeTrades)
        {
            Print("send new posinfo to clients");
            Send(); 
           // bChangeTrades = false;
        }
    }
    string message = BuildPositionMessage();
    if(StringLen(message) > 0)
    {
        // Convert string to uchar array properly
        ArrayResize(data, StringLen(message));
        for(int i = 0; i < StringLen(message); i++)
            data[i] = (uchar)StringGetCharacter(message, i);
            
       // bChangeTrades = true;
        Print("Position message prepared: ", message);
    }
}

//+------------------------------------------------------------------+
//| Build position message with tickets                              |
//+------------------------------------------------------------------+
string BuildPositionMessage()
{
    string message = "";
    
    // Arrays for current positions
    ulong currentTickets[];
    string currentSymbols[];
    double currentVolumes[];
    int currentTypes[];
    
    // Get current positions
    int total = PositionsTotal();
    ArrayResize(currentTickets, total);
    ArrayResize(currentSymbols, total);
    ArrayResize(currentVolumes, total);
    ArrayResize(currentTypes, total);
    
    for(int i = 0; i < total; i++)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            currentTickets[i] = ticket;
            currentSymbols[i] = PositionGetString(POSITION_SYMBOL);
            currentVolumes[i] = PositionGetDouble(POSITION_VOLUME);
            currentTypes[i] = (int)PositionGetInteger(POSITION_TYPE);
            
            // Send OPEN signal for current position
            double lot = currentVolumes[i];
            if(currentTypes[i] == POSITION_TYPE_SELL)
                lot = -lot;
                
            message += "<<OPEN|" + currentSymbols[i] + "|" + 
                      DoubleToString(lot, 2) + "|" + IntegerToString(TicketToMagic(ticket)) + ">>";
        }
    }
    
    // Check for closed positions (existed in previous but not in current)
    for(int i = 0; i < ArraySize(previousTickets); i++)
    {
        bool found = false;
        for(int j = 0; j < ArraySize(currentTickets); j++)
        {
            if(previousTickets[i] == currentTickets[j])
            {
                found = true;
                break;
            }
        }
        
        if(!found)
        {
            // Position was closed, send CLOSE signal
            message += "<<CLOSE|" + previousSymbols[i] + "|" + 
                      IntegerToString(TicketToMagic(previousTickets[i])) + ">>";
        }
    }
    
    // Update previous positions
    ArrayCopy(previousTickets, currentTickets);
    ArrayCopy(previousSymbols, currentSymbols);
    ArrayCopy(previousVolumes, currentVolumes);
    ArrayCopy(previousTypes, currentTypes);
    
    return message;
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+


//+------------------------------------------------------------------+
//| Start server                                                     |
//+------------------------------------------------------------------+
void StartServer(string addr, ushort port)
{
    char wsaData[]; 
    ArrayResize(wsaData, sizeof(WSAData));
    int res = WSAStartup(MAKEWORD(2, 2), wsaData);
    if(res != 0) 
    { 
        Print("-WSAStartup failed error: " + string(res)); 
        return; 
    }

    server = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if(server == INVALID_SOCKET64) 
    { 
        Print("-Create failed error: " + WSAErrorDescript(WSAGetLastError())); 
        CloseClean(); 
        return; 
    }

    Print("try bind..." + addr + ":" + string(port));

    char ch[]; 
    StringToCharArray(addr, ch);
    sockaddr_in addrin;
    addrin.sin_family = AF_INET;
    addrin.sin_addr.u.S_addr = inet_addr(ch);
    addrin.sin_port = htons(port);
    
    ref_sockaddr_in ref; 
    ref.in = addrin;
    
    if(bind(server, ref.ref, sizeof(addrin)) == SOCKET_ERROR)
    {
        int err = WSAGetLastError();
        Print("-Bind failed error: " + WSAErrorDescript(err) + ". Cleanup socket"); 
        CloseClean(); 
        return;
    }

    int non_block = 1;
    res = ioctlsocket(server, FIONBIO, non_block);
    if(res != NO_ERROR) 
    { 
        Print("ioctlsocket failed error: " + string(res)); 
        CloseClean(); 
        return; 
    }

    if(listen(server, SOMAXCONN) == SOCKET_ERROR) 
    { 
        Print("Listen failed with error: ", WSAErrorDescript(WSAGetLastError())); 
        CloseClean(); 
        return; 
    }

    Print("start server ok");
}

//+------------------------------------------------------------------+
//| Accept clients                                                   |
//+------------------------------------------------------------------+
void AcceptClients()
{
    if(server == INVALID_SOCKET64) 
        return;

    SOCKET64 client = INVALID_SOCKET64;
    do
    {
        char clientRef[32];
        int len = 32;
        client = accept(server, clientRef, len);
        
        if(client == INVALID_SOCKET64)
        {
            int err = WSAGetLastError();
            if(err == WSAEWOULDBLOCK) 
                Comment("\nWAITING CLIENT (" + string(TimeCurrent()) + ")");
            else 
            { 
                Print("Accept failed with error: ", WSAErrorDescript(err)); 
                CloseClean(); 
            }
            return;
        }

        int non_block = 1;
        int res = ioctlsocket(client, FIONBIO, non_block);
        if(res != NO_ERROR) 
        { 
            Print("ioctlsocket failed error: " + string(res)); 
            continue; 
        }

        int n = ArraySize(conns); 
        ArrayResize(conns, n + 1);
        conns[n] = client;
        bChangeTrades = true;

        printf("Accept new client: socket #%d", (int)client);
    }
    while(client != INVALID_SOCKET64);
}

//+------------------------------------------------------------------+
//| Send data to clients                                             |
//+------------------------------------------------------------------+
void Send()
{
    int len = ArraySize(data);
    for(int i = ArraySize(conns) - 1; i >= 0; --i)
    {
        if(conns[i] == INVALID_SOCKET64) 
            continue;
            
        char charData[];
        ArrayResize(charData, len);
        for(int j = 0; j < len; j++)
            charData[j] = (char)data[j];
            
        int res = send(conns[i], charData, len, 0);
        if(res == SOCKET_ERROR) 
        { 
            Print("-Send failed error: " + WSAErrorDescript(WSAGetLastError()) + ". close socket"); 
            Close(conns[i]); 
        }
    }
}

//+------------------------------------------------------------------+
//| Close and cleanup                                                |
//+------------------------------------------------------------------+
void CloseClean()
{
    printf("Shutdown server and %d connections", ArraySize(conns));
    if(server != INVALID_SOCKET64) 
    { 
        closesocket(server); 
        server = INVALID_SOCKET64; 
    }
    
    for(int i = ArraySize(conns) - 1; i >= 0; --i) 
        Close(conns[i]);
        
    ArrayResize(conns, 0);
    WSACleanup();
}

//+------------------------------------------------------------------+
//| Close single socket                                              |
//+------------------------------------------------------------------+
void Close(SOCKET64 &asock)
{
    if(asock == INVALID_SOCKET64) 
        return;
        
    if(shutdown(asock, SD_BOTH) == SOCKET_ERROR) 
        Print("-Shutdown failed error: " + WSAErrorDescript(WSAGetLastError()));
        
    closesocket(asock);
    asock = INVALID_SOCKET64;
}

