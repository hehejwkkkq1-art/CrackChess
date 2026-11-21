-- Direct native-image replacement; crops use decoded texture dimensions.
-- Custom skins are local visuals. Original images remain available for board recognition.
-- ChessHub: visible-board analysis and optional click-based Auto Move.
-- Place 130878180532794; only the original observed piece theme is supported.
-- Midgame: watch one legal move to establish turn, or select Turn explicitly.
-- Historic castling rights and en passant are unknown on attachment; no guesses in search.
-- Auto Move is OFF initially; enabling it also enables arrows. F8 stops it.
-- Search budgets: Fast .6s / Balanced 2s (default) / Deep 6s.
-- Uses completed local analysis, revalidates legal moves and waits for acknowledgement.
-- Input must be available in the runtime. No remotes, server changes or networking.
-- No unconditional retries. Unknown promotion pickers require manual selection.
-- Local engine, not Stockfish; no guarantee of an objectively best or instant move.
local Engine=(function()
local E = {}
local abs, band = math.abs, bit32.band
local knight = {-33,-31,-18,-14,14,18,31,33}
local bishop, rook = {-17,-15,15,17}, {-16,-1,1,16}
local king = {-17,-16,-15,-1,1,15,16,17}
local values = {100,320,335,500,900,0}
local function valid(s) return s >= 0 and s < 128 and band(s, 0x88) == 0 end
local function sign(p) return p > 0 and 1 or -1 end
function E.fen(fen)
    local fields = string.split(fen, " ")
    local b = {}; for i=0,127 do b[i]=0 end
    local rank, file = 7,0
    local types = {p=1,n=2,b=3,r=4,q=5,k=6}
    for c in fields[1]:gmatch(".") do
        if c == "/" then rank-=1;file=0
        elseif tonumber(c) then file+=tonumber(c)
        else b[rank*16+file]=(c==c:upper() and 1 or -1)*assert(types[c:lower()]);file+=1 end
    end
    local rights=0
    for c,v in pairs({K=1,Q=2,k=4,q=8}) do if (fields[3] or "-"):find(c,1,true) then rights+=v end end
    local ep=-1
    if fields[4] and fields[4]~="-" then ep=(tonumber(fields[4]:sub(2,2))-1)*16+fields[4]:byte(1)-97 end
    return {b=b,side=fields[2]=="b" and -1 or 1,rights=rights,ep=ep,half=tonumber(fields[5]) or 0}
end
function E.start() return E.fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1") end
function E.same(a,b)
    for r=0,7 do for f=0,7 do local s=r*16+f;if a[s]~=b[s] then return false end end end
    return true
end
function E.attacked(pos,square,by)
    local b=pos.b
    for _,d in ipairs({by*16-1,by*16+1}) do
        local s=square-d;if valid(s) and b[s]==by then return true end
    end
    for _,d in ipairs(knight) do local s=square+d;if valid(s) and b[s]==by*2 then return true end end
    for _,d in ipairs(king) do local s=square+d;if valid(s) and b[s]==by*6 then return true end end
    for _,d in ipairs(king) do
        local diagonal=abs(d)==15 or abs(d)==17
        local s=square+d
        while valid(s) do
            local p=b[s]
            if p~=0 then
                if sign(p)==by and (abs(p)==5 or abs(p)==(diagonal and 3 or 4)) then return true end
                break
            end
            s+=d
        end
    end
    return false
end
local function kings(pos)
    if pos.wk ~= nil and pos.bk ~= nil then return end
    pos.wk, pos.bk = -1, -1
    for r=0,7 do for f=0,7 do
        local square=r*16+f
        if pos.b[square]==6 then pos.wk=square elseif pos.b[square]==-6 then pos.bk=square end
    end end
end
function E.check(pos,side)
    kings(pos)
    local square=side==1 and pos.wk or pos.bk
    return square<0 or E.attacked(pos,square,-side)
end
local rookRights = {[0]=2,[7]=1,[112]=8,[119]=4}
function E.make(pos,m)
    local b=pos.b
    local piece,captured=b[m.f],b[m.t]
    local undo={piece=piece,captured=captured,side=pos.side,rights=pos.rights,ep=pos.ep,
        half=pos.half,wk=pos.wk,bk=pos.bk,key=pos.key}
    b[m.f]=0;b[m.t]=m.prom and m.prom*pos.side or piece
    if m.ep then
        undo.epSquare=m.t-pos.side*16;undo.epPiece=b[undo.epSquare];b[undo.epSquare]=0
    end
    if m.castle then
        undo.rf=m.t>m.f and m.f+3 or m.f-4
        undo.rt=m.t>m.f and m.f+1 or m.f-1
        undo.rook=b[undo.rf];undo.rookDestination=b[undo.rt]
        b[undo.rt],b[undo.rf]=b[undo.rf],0
    end
    local remove=0
    if piece==6 then remove=3 elseif piece==-6 then remove=12 end
    remove=bit32.bor(remove,rookRights[m.f] or 0,rookRights[m.t] or 0)
    pos.rights=band(pos.rights,bit32.bnot(remove))
    if piece==6 then pos.wk=m.t elseif piece==-6 then pos.bk=m.t end
    pos.ep=abs(piece)==1 and abs(m.t-m.f)==32 and (m.t+m.f)/2 or -1
    pos.half=(abs(piece)==1 or captured~=0 or m.ep) and 0 or pos.half+1
    pos.side=-pos.side;pos.key=nil
    return undo
end
function E.unmake(pos,m,u)
    pos.b[m.f],pos.b[m.t]=u.piece,u.captured
    if u.epSquare then pos.b[u.epSquare]=u.epPiece end
    if u.rf then pos.b[u.rf],pos.b[u.rt]=u.rook,u.rookDestination end
    pos.side,pos.rights,pos.ep,pos.half=u.side,u.rights,u.ep,u.half
    pos.wk,pos.bk,pos.key=u.wk,u.bk,u.key
end
function E.apply(pos,m)
    local copy={b=table.clone(pos.b),side=pos.side,rights=pos.rights,ep=pos.ep,half=pos.half,wk=pos.wk,bk=pos.bk}
    E.make(copy,m)
    return copy
end
function E.moves(pos)
    kings(pos)
    local b,side=pos.b,pos.side
    local pseudo={}
    local function add(f,t,extra)
        if abs(b[t])==6 then return end
        if abs(b[f])==1 and (math.floor(t/16)==0 or math.floor(t/16)==7) then
            for _,p in ipairs({5,4,3,2}) do table.insert(pseudo,{f=f,t=t,prom=p}) end
        else local m=extra or {};m.f=f;m.t=t;table.insert(pseudo,m) end
    end
    for rank=0,7 do for file=0,7 do
        local f=rank*16+file;local piece=b[f]
        if piece==0 or sign(piece)~=side then continue end
        local kind=abs(piece)
        if kind==1 then
            local step=side*16;local t=f+step
            if valid(t) and b[t]==0 then
                add(f,t)
                if rank==(side==1 and 1 or 6) and b[t+step]==0 then add(f,t+step) end
            end
            for _,d in ipairs({step-1,step+1}) do
                t=f+d
                if valid(t) then
                    if b[t]~=0 and sign(b[t])~=side then add(f,t)
                    elseif t==pos.ep and b[t]==0 and b[t-step]==-side then add(f,t,{ep=true}) end
                end
            end
        else
            local directions=kind==2 and knight or kind==3 and bishop or kind==4 and rook or king
            local sliding=kind==3 or kind==4 or kind==5
            for _,d in ipairs(directions) do
                local t=f+d
                while valid(t) do
                    if b[t]~=0 and sign(b[t])==side then break end
                    add(f,t)
                    if b[t]~=0 or not sliding then break end
                    t+=d
                end
            end
            local home=side==1 and 4 or 116
            if kind==6 and f==home and not E.attacked(pos,f,-side) then
                local ks,qs=side==1 and 1 or 4,side==1 and 2 or 8
                if band(pos.rights,ks)~=0 and b[f+1]==0 and b[f+2]==0 and b[f+3]==side*4
                    and not E.attacked(pos,f+1,-side) and not E.attacked(pos,f+2,-side) then add(f,f+2,{castle=true}) end
                if band(pos.rights,qs)~=0 and b[f-1]==0 and b[f-2]==0 and b[f-3]==0 and b[f-4]==side*4
                    and not E.attacked(pos,f-1,-side) and not E.attacked(pos,f-2,-side) then add(f,f-2,{castle=true}) end
            end
        end
    end end
    local legal={}
    for _,m in ipairs(pseudo) do
        local undo=E.make(pos,m)
        local allowed=not E.check(pos,side)
        E.unmake(pos,m,undo)
        if allowed then table.insert(legal,m) end
    end
    return legal
end
function E.uci(m)
    local function name(s)return string.char(97+s%16)..tostring(math.floor(s/16)+1)end
    return name(m.f)..name(m.t)..(m.prom and ({[2]="n",[3]="b",[4]="r",[5]="q"})[m.prom] or "")
end
local cache,cacheCount={},0
local function positionKey(pos)
    if pos.key then return pos.key end
    local chars={}
    for r=0,7 do for f=0,7 do chars[#chars+1]=string.char(pos.b[r*16+f]+7) end end
    local board=table.concat(chars)
    pos.key=board..string.char(pos.side+1,pos.rights,pos.ep+1)..tostring(pos.half)
    return pos.key
end
local function evaluate(pos)
    local score,phase=0,0
    local pawns={[1]={},[-1]={}}
    local bishops={[1]=0,[-1]=0}
    for side=-1,1,2 do for f=0,7 do pawns[side][f]=0 end end
    for r=0,7 do for f=0,7 do
        local piece=pos.b[r*16+f]
        if piece~=0 then
            local side,kind=sign(piece),abs(piece)
            if kind==1 then pawns[side][f]+=1
            elseif kind==3 then bishops[side]+=1 end
            phase+=({[1]=0,[2]=1,[3]=1,[4]=2,[5]=4,[6]=0})[kind]
        end
    end end
    local middlegame=math.min(24,phase)/24
    for rank=0,7 do for file=0,7 do
        local p=pos.b[rank*16+file]
        if p==0 then continue end
        local kind,side=abs(p),sign(p)
        local central=7-abs(file-3.5)-abs(rank-3.5)
        local advance=side==1 and rank or 7-rank
        local bonus=0
        if kind==1 then
            bonus=advance*6+central*2
            if (pawns[side][file-1] or 0)+(pawns[side][file+1] or 0)==0 then bonus-=13 end
            if pawns[side][file]>1 then bonus-=11 end
            local passed=true
            for enemyRank=rank+side,side==1 and 7 or 0,side do
                for enemyFile=math.max(0,file-1),math.min(7,file+1) do
                    if pos.b[enemyRank*16+enemyFile]==-side then passed=false;break end
                end
                if not passed then break end
            end
            if passed then bonus+=advance*advance*(1+2*(1-middlegame)) end
        elseif kind==2 then bonus=central*11-(advance==0 and 12 or 0)
        elseif kind==3 then bonus=central*7+(bishops[side]>=2 and 17 or 0)
        elseif kind==4 then
            bonus=central*2+(advance==6 and 18 or 0)
            if pawns[side][file]==0 then bonus+=pawns[-side][file]==0 and 22 or 11 end
        elseif kind==5 then bonus=central*3-(advance>2 and middlegame*7 or 0)
        elseif kind==6 then
            local safety=-central*9-(advance>1 and 18 or 0)
            if advance==0 and (file==2 or file==6) then safety+=30 end
            for f=math.max(0,file-1),math.min(7,file+1) do
                local front=rank+side
                if front>=0 and front<=7 and pos.b[front*16+f]==side then safety+=9 end
            end
            bonus=safety*middlegame+central*12*(1-middlegame)
        end
        if kind>=2 and kind<=5 then
            local directions=kind==2 and knight or kind==3 and bishop or kind==4 and rook or king
            local mobility=0
            for _,d in ipairs(directions) do
                local square=rank*16+file+d
                while valid(square) do
                    if pos.b[square]~=0 and sign(pos.b[square])==side then break end
                    mobility+=1
                    if kind==2 or pos.b[square]~=0 then break end
                    square+=d
                end
            end
            bonus+=mobility*(({[2]=3,[3]=3,[4]=2,[5]=1})[kind])
        end
        score+=side*(values[kind]+bonus)
    end end
    return score*pos.side+8
end
function E.search(pos,seconds,cancel,publish)
    -- Search has a private mutable board, so yielding never exposes a speculative move to the UI.
    pos={b=table.clone(pos.b),side=pos.side,rights=pos.rights,ep=pos.ep,half=pos.half,wk=pos.wk,bk=pos.bk}
    local started=os.clock()
    local deadline=started+(seconds or 2.4)
    local nodes,lastYield=0,started
    local aborted=false
    local killers,history={},{}
    local hits=0
    local function tick()
        nodes+=1
        if nodes%32==0 then
            if os.clock()-lastYield>.006 then task.wait();lastYield=os.clock() end
            if os.clock()>=deadline or (cancel and cancel()) then aborted=true end
        end
        return aborted
    end
    local function moveId(m)return m.f*1024+m.t*8+(m.prom or 0)end
    local function sameMove(a,b)return a and b and a.f==b.f and a.t==b.t and a.prom==b.prom end
    local function order(p,moves,best,ply)
        local ranked={}
        for i,m in ipairs(moves) do
            local capture=values[abs(p.b[m.t])] or 0
            local value
            if sameMove(m,best) then value=10000000
            elseif capture>0 or m.ep or m.prom then value=100000+capture*16-(values[abs(p.b[m.f])] or 0)+(m.ep and 1600 or 0)+(m.prom and values[m.prom]*10 or 0)
            elseif killers[ply] and sameMove(killers[ply],m) then value=90000
            else value=history[(p.side+1)*200000+moveId(m)] or 0 end
            ranked[i]={move=m,score=value}
        end
        table.sort(ranked,function(a,b)return a.score>b.score end)
        for i,item in ipairs(ranked) do moves[i]=item.move end
    end
    local function mateToCache(value,ply)
        if value>99000 then return value+ply elseif value< -99000 then return value-ply end
        return value
    end
    local function mateFromCache(value,ply)
        if value>99000 then return value-ply elseif value< -99000 then return value+ply end
        return value
    end
    local function negamax(p,depth,alpha,beta,ply,qleft,extensionsLeft)
        if tick() then return 0 end
        local alphaOriginal=alpha
        local checked=E.check(p,p.side)
        if depth>0 and checked and extensionsLeft>0 then depth+=1;extensionsLeft-=1 end
        local key,entry
        if depth>0 then
            key=positionKey(p)..string.char(extensionsLeft);entry=cache[key]
            if entry and entry.depth>=depth then
                local score=mateFromCache(entry.score,ply)
                if entry.flag=="exact" or (entry.flag=="lower" and score>=beta) or (entry.flag=="upper" and score<=alpha) then hits+=1;return score end
            end
        end
        local moves=E.moves(p)
        if #moves==0 then return checked and -100000+ply or 0 end
        if p.half>=100 then return 0 end
        if depth<=0 then
            if qleft<=0 then return evaluate(p) end
            if not checked then
                local stand=evaluate(p)
                if stand>=beta then return stand end
                alpha=math.max(alpha,stand)
                local captures={}
                for _,m in ipairs(moves) do if p.b[m.t]~=0 or m.ep or m.prom then captures[#captures+1]=m end end
                moves=captures
            end
        end
        order(p,moves,entry and entry.best,ply)
        local best,bestValue=nil,-math.huge
        local first=true
        for moveNumber,m in ipairs(moves) do
            local quiet=p.b[m.t]==0 and not m.ep and not m.prom
            local undo=E.make(p,m)
            local child=p
            local q=depth<=0 and qleft-1 or qleft
            local score
            if first or depth<=1 then score=-negamax(child,depth-1,-beta,-alpha,ply+1,q,extensionsLeft)
            else
                local reduced=depth>=4 and moveNumber>=5 and quiet and not checked
                    and not E.check(child,child.side) and not (killers[ply] and sameMove(killers[ply],m))
                score=-negamax(child,depth-(reduced and 2 or 1),-alpha-1,-alpha,ply+1,q,extensionsLeft)
                -- A promising reduced move must be verified again at full depth.
                if reduced and not aborted and score>alpha then
                    score=-negamax(child,depth-1,-alpha-1,-alpha,ply+1,q,extensionsLeft)
                end
                if not aborted and score>alpha and score<beta then score=-negamax(child,depth-1,-beta,-alpha,ply+1,q,extensionsLeft) end
            end
            E.unmake(p,m,undo)
            first=false
            if aborted then return 0 end
            if score>bestValue then bestValue,best=score,m end
            alpha=math.max(alpha,score)
            if alpha>=beta then
                if p.b[m.t]==0 and not m.ep and not m.prom then
                    killers[ply]=m
                    local id=(p.side+1)*200000+moveId(m)
                    history[id]=math.min(80000,(history[id] or 0)+depth*depth)
                end
                break
            end
        end
        if key and best then
            if cacheCount>24000 then cache={};cacheCount=0 end
            if not cache[key] then cacheCount+=1 end
            cache[key]={depth=depth,score=mateToCache(bestValue,ply),best=best,
                flag=bestValue<=alphaOriginal and "upper" or bestValue>=beta and "lower" or "exact"}
        end
        if depth<=0 then return alpha end
        return bestValue
    end
    local moves=E.moves(pos)
    if #moves==0 then return nil,{depth=0,nodes=0} end
    local function principalVariation(first,limit)
        local line={}
        local current,move=pos,first
        local extensionBudget=2
        for ply=1,math.min(limit,7) do
            if not move then break end
            local legal=nil
            for _,candidate in ipairs(E.moves(current)) do if sameMove(candidate,move) then legal=candidate;break end end
            if not legal then break end
            line[#line+1]=E.uci(legal)
            current=E.apply(current,legal)
            if E.check(current,current.side) and extensionBudget>0 then extensionBudget-=1 end
            local entry=cache[positionKey(current)..string.char(extensionBudget)]
            move=entry and entry.best
        end
        return line
    end
    local best,completed,completedScore=nil,0,nil
    local completedLine={}
    for depth=1,12 do
        local rootEntry=cache[positionKey(pos).."root"]
        order(pos,moves,best or (rootEntry and rootEntry.best),0)
        local iterationBest,scoreBest=nil,-100001
        for _,m in ipairs(moves) do
            local undo=E.make(pos,m)
            local score=-negamax(pos,depth-1,-100001,-scoreBest,1,6,2)
            E.unmake(pos,m,undo)
            if aborted then break end
            if score>scoreBest then scoreBest,iterationBest=score,m end
        end
        if aborted then break end
        best,completed,completedScore=iterationBest,depth,scoreBest
        completedLine=principalVariation(best,depth)
        local rootKey=positionKey(pos).."root"
        if not cache[rootKey] then cacheCount+=1 end
        cache[rootKey]={best=best,depth=depth}
        if publish then publish(best,{depth=depth,nodes=nodes,score=scoreBest,elapsed=os.clock()-started,cacheHits=hits,pv=completedLine}) end
        if abs(scoreBest)>99000 or os.clock()>=deadline then break end
        task.wait()
        if cancel and cancel() then aborted=true;break end
    end
    return best,{depth=completed,nodes=nodes,score=completedScore,elapsed=os.clock()-started,cacheHits=hits,pv=completedLine,cancelled=cancel and cancel() or false}
end
return E

end)()
-- Classic desktop/touch controls.
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local deadline = os.clock() + 20
while not Players.LocalPlayer and os.clock() < deadline do task.wait(.1) end
local player = Players.LocalPlayer
assert(player, "ChessHub: join the game first")

local function make(class, props)
    local object = Instance.new(class)
    for name, value in pairs(props) do if name ~= "Parent" then object[name] = value end end
    if props.Parent then object.Parent = props.Parent end
    return object
end
local gui = make("ScreenGui", {
    Name = "ChessHubMoveHint", ResetOnSpawn = false, IgnoreGuiInset = false,
    DisplayOrder = 60, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
local containers = {}
local function add(value)
    if typeof(value) == "Instance" and not table.find(containers, value) then table.insert(containers, value) end
end
if type(gethui) == "function" then
    local ok, value = pcall(gethui)
    if ok then add(value) end
end
pcall(function() add(game:GetService("CoreGui")) end)
add(player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 5))
local attached = false
for _, container in ipairs(containers) do
    local ok = pcall(function() gui.Parent = container; assert(gui.Parent == container) end)
    if ok then attached = true; break end
end
if not attached then gui:Destroy(); error("ChessHub: unable to attach UI", 0) end
for _, container in ipairs(containers) do
    pcall(function()
        for _, other in ipairs(container:GetChildren()) do
            if other ~= gui and (other.Name == gui.Name or other.Name == "ChessHubClassic") then other:Destroy() end
        end
    end)
end

local connections = {}
local function on(signal, fn)
    local connection = signal:Connect(fn)
    table.insert(connections, connection)
    return connection
end
gui.Destroying:Connect(function()
    for _, connection in ipairs(connections) do connection:Disconnect() end
    table.clear(connections)
end)
local c = {
    text = Color3.fromRGB(211, 216, 230), dim = Color3.fromRGB(145, 155, 174),
    blue = Color3.fromRGB(58, 61, 130), border = Color3.fromRGB(94, 107, 168),
    box = Color3.fromRGB(84, 89, 95), fill = Color3.fromRGB(135, 146, 151),
}
local function text(parent, value, pos, size, color)
    return make("TextLabel", {Parent = parent, Text = value, Position = pos, Size = size,
        BackgroundTransparency = 1, TextColor3 = color or c.text, TextSize = 12,
        Font = Enum.Font.Code, TextXAlignment = Enum.TextXAlignment.Left, BorderSizePixel = 0})
end
local function hit(parent, pos, size)
    return make("TextButton", {Parent = parent, Text = "", Position = pos, Size = size,
        BackgroundTransparency = 1, BorderSizePixel = 0, AutoButtonColor = false})
end
local window = make("Frame", {Parent = gui, Name = "Window", Position = UDim2.fromOffset(12, 12),
    AnchorPoint = Vector2.zero, Size = UDim2.fromOffset(354, 372),
    BackgroundColor3 = Color3.fromRGB(8, 13, 18), BackgroundTransparency = .24,
    BorderSizePixel = 0, Active = true, ClipsDescendants = true})
make("UIStroke", {Parent = window, Color = c.border, Thickness = 1, Transparency = .25})
local scale = make("UIScale", {Parent = window, Scale = 1})
local title = make("Frame", {Parent = window, Size = UDim2.new(1, 0, 0, 22),
    BackgroundColor3 = c.blue, BackgroundTransparency = .12, BorderSizePixel = 0})
local fold = hit(title, UDim2.fromOffset(0, 0), UDim2.fromOffset(22, 22))
local foldText = text(fold, "v", UDim2.fromOffset(6, 0), UDim2.fromOffset(15, 22))
text(title, "CrackHub | Chess", UDim2.fromOffset(24, 0), UDim2.new(1, -68, 1, 0))
local dragHandle = hit(title, UDim2.fromOffset(22, 0), UDim2.new(1, -47, 1, 0))
local close = hit(title, UDim2.new(1, -24, 0, 0), UDim2.fromOffset(24, 22))
text(close, "x", UDim2.fromOffset(7, 0), UDim2.fromOffset(17, 22), c.dim)
on(close.Activated, function() window.Visible = false end)
local content = make("ScrollingFrame", {Parent = window, Position = UDim2.fromOffset(4, 26),
    Size = UDim2.new(1, -8, 1, -45), BackgroundTransparency = 1, BorderSizePixel = 0,
    ScrollBarThickness = 2, ScrollBarImageColor3 = c.border,
    CanvasSize = UDim2.fromOffset(0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y})
make("UIListLayout", {Parent = content, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4)})
local status = text(window, "Move Hint: OFF", UDim2.new(0, 8, 1, -17), UDim2.new(1, -16, 0, 15), c.dim)
status.TextSize = 10
local isTouch = UIS.TouchEnabled or not UIS.KeyboardEnabled
local floating = make("TextButton", {Parent = gui, Name = "TouchToggle", Text = "CH",
    Font = Enum.Font.Code, TextSize = 15, TextColor3 = c.text, Size = UDim2.fromOffset(46, 40),
    Position = UDim2.new(0, 16, .5, -20), BackgroundColor3 = c.blue,
    BackgroundTransparency = .1, BorderSizePixel = 0, Active = true, AutoButtonColor = false, Visible = isTouch})
make("UIStroke", {Parent = floating, Color = c.border, Thickness = 1})
local collapsed = false
on(fold.Activated, function()
    collapsed = not collapsed
    foldText.Text = collapsed and ">" or "v"
    content.Visible, status.Visible = not collapsed, not collapsed
    window.Size = UDim2.fromOffset(354, collapsed and 22 or 372)
end)

local activeSlider=nil
local state={hint=false,auto=false,budget=2.0,autoEpoch=0,attachEpoch=0,turn=0,playerSide=0,magnus=false,sahur=false,skinBoth=false}
local autoMessage=nil
local setAuto
local header=make("Frame",{Parent=content,Size=UDim2.new(1,-3,0,19),BackgroundColor3=c.blue,BackgroundTransparency=.16,BorderSizePixel=0})
text(header,"v  Chess",UDim2.fromOffset(8,0),UDim2.new(1,-8,1,0))
local function toggleRow(label,order)
    local row=make("TextButton",{Parent=content,LayoutOrder=order,Size=UDim2.new(1,-3,0,25),BackgroundTransparency=1,Text="",AutoButtonColor=false})
    local box=make("Frame",{Parent=row,Position=UDim2.fromOffset(5,4),Size=UDim2.fromOffset(17,17),BackgroundColor3=c.box,BackgroundTransparency=.28,BorderSizePixel=0})
    local tick=text(box,"v",UDim2.fromOffset(2,-1),UDim2.fromOffset(15,17));tick.Visible=false;tick.TextSize=17
    text(row,label,UDim2.fromOffset(28,0),UDim2.new(1,-30,1,0))
    return row,tick
end
local hintRow,hintMark=toggleRow("Move Hint",1)
local autoRow,autoMark=toggleRow("Auto Move",2)
setAuto=function(enabled,reason)
    state.auto=enabled;state.autoEpoch+=1;autoMark.Visible=enabled;autoMessage=reason
    if enabled then state.hint=true;hintMark.Visible=true end
end
on(hintRow.Activated,function()
    state.hint=not state.hint;hintMark.Visible=state.hint
    if not state.hint then setAuto(false) end
end)
on(autoRow.Activated,function()setAuto(not state.auto)end)
on(UIS.InputBegan,function(input)
    if input.KeyCode==Enum.KeyCode.F8 then setAuto(false,"Auto Move stopped (F8)") end
end)
local speed=make("TextButton",{Parent=content,LayoutOrder=3,Size=UDim2.new(1,-3,0,24),BackgroundColor3=c.box,BackgroundTransparency=.65,BorderSizePixel=0,Text="",AutoButtonColor=false})
local speedText=text(speed,"Calculation: Balanced (2s)  >",UDim2.fromOffset(5,0),UDim2.new(1,-10,1,0))
local mode=2
on(speed.Activated,function()
    mode=mode%3+1;state.budget=({.6,2,6})[mode]
    speedText.Text="Calculation: "..({"Fast (0.6s)","Balanced (2s)","Deep (6s)"})[mode].."  >"
end)
local function choice(label,order,callback)
    local row=make("TextButton",{Parent=content,LayoutOrder=order,Size=UDim2.new(1,-3,0,24),BackgroundColor3=c.box,BackgroundTransparency=.65,BorderSizePixel=0,Text="",AutoButtonColor=false})
    local caption=text(row,label,UDim2.fromOffset(5,0),UDim2.new(1,-10,1,0))
    on(row.Activated,function()callback(caption)end)
end
local detectedRow=make("Frame",{Parent=content,LayoutOrder=4,Size=UDim2.new(1,-3,0,30),BackgroundTransparency=1})
local detectedText=text(detectedRow,"Side: detecting / Turn: detecting",UDim2.fromOffset(5,0),UDim2.new(1,-10,1,0),c.dim)
detectedText.TextSize=11;detectedText.TextWrapped=true
local magnusRow,magnusMark=toggleRow("Custom Pieces: Magnus Carlsen",6)
on(magnusRow.Activated,function()state.magnus=not state.magnus;magnusMark.Visible=state.magnus end)
choice("Apply Pieces: Only Mine  >",7,function(caption)
    state.skinBoth=not state.skinBoth
    caption.Text="Apply Pieces: "..(state.skinBoth and "Both Sides" or "Only Mine").."  >"
end)
local sahurRow,sahurMark=toggleRow("Custom Board: Tung Tung Tung Sahur",8)
on(sahurRow.Activated,function()state.sahur=not state.sahur;sahurMark.Visible=state.sahur end)
local skinStatusFrame=make("Frame",{Parent=content,LayoutOrder=9,Size=UDim2.new(1,-3,0,38),BackgroundTransparency=1})
local skinNotice=text(skinStatusFrame,"Custom skins: OFF (local visuals)",UDim2.fromOffset(5,0),UDim2.new(1,-10,1,0),c.dim)
skinNotice.TextSize=11;skinNotice.TextWrapped=true
local note=make("Frame",{Parent=content,LayoutOrder=10,Size=UDim2.new(1,0,0,36),BackgroundTransparency=1})
local noteText=text(note,isTouch and "Tap CH to toggle / drag to move" or "Insert: menu / F8: stop Auto Move",UDim2.fromOffset(5,0),UDim2.new(1,-10,1,0),c.dim)
noteText.TextSize=11;noteText.TextWrapped=true
local dragging = nil
local function beginDrag(control, target, tapToggle)
    on(control.InputBegan, function(input)
        if dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
        dragging = {pointer = input, target = target, start = input.Position, origin = target.Position, moved = false, tapToggle = tapToggle}
    end)
end
beginDrag(dragHandle, window, false)
beginDrag(floating, floating, true)
local function clampControl(target)
    local size, position = gui.AbsoluteSize, target.Position
    if size.X <= 0 or size.Y <= 0 then return end
    local w, h = target.AbsoluteSize.X, target.AbsoluteSize.Y
    local anchor = target.AnchorPoint
    local x, y = position.X.Scale * size.X + position.X.Offset, position.Y.Scale * size.Y + position.Y.Offset
    target.Position = UDim2.fromOffset(math.clamp(x, w * anchor.X, math.max(w * anchor.X, size.X - w * (1 - anchor.X))), math.clamp(y, h * anchor.Y, math.max(h * anchor.Y, size.Y - h * (1 - anchor.Y))))
end
on(UIS.InputChanged, function(input)
    if activeSlider and (input == activeSlider.pointer or (activeSlider.pointer.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseMovement)) then
        activeSlider.update(input.Position.X)
    end
    local d = dragging
    if not d then return end
    if input ~= d.pointer and not (d.pointer.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseMovement) then return end
    local delta = input.Position - d.start
    if Vector2.new(delta.X, delta.Y).Magnitude > 6 then d.moved = true end
    if d.moved then
        local size = gui.AbsoluteSize
        d.target.Position = UDim2.fromOffset(d.origin.X.Scale * size.X + d.origin.X.Offset + delta.X, d.origin.Y.Scale * size.Y + d.origin.Y.Offset + delta.Y)
        clampControl(d.target)
    end
end)
on(UIS.InputEnded, function(input)
    if activeSlider and input == activeSlider.pointer then activeSlider = nil end
    if dragging and input == dragging.pointer then
        local delta = input.Position - dragging.start
        if dragging.tapToggle and not dragging.moved and Vector2.new(delta.X, delta.Y).Magnitude <= 6 then window.Visible = not window.Visible end
        dragging = nil
    end
end)
on(UIS.WindowFocusReleased, function() dragging, activeSlider = nil, nil end)
on(UIS.InputBegan, function(input)
    if not UIS:GetFocusedTextBox() and input.KeyCode == Enum.KeyCode.Insert then window.Visible = not window.Visible end
end)
local function fit()
    local size = gui.AbsoluteSize
    if size.X < 1 or size.Y < 1 then return end
    scale.Scale = math.min(1, math.max(.1, (size.X - 18) / 354), math.max(.1, (size.Y - 18) / 372))
    clampControl(window); clampControl(floating)
end
on(gui:GetPropertyChangedSignal("AbsoluteSize"), fit)
local function inputMode()
    floating.Visible = UIS.TouchEnabled or not UIS.KeyboardEnabled
end
on(UIS:GetPropertyChangedSignal("TouchEnabled"), inputMode)
on(UIS:GetPropertyChangedSignal("KeyboardEnabled"), inputMode)
fit()

-- Adapter for the board/image assets observed in the supplied report.
local imagePieces = {
    ["133288029788689"]=4,["111025513068016"]=2,["85269847273836"]=3,
    ["128494764910602"]=5,["108253639129512"]=6,["130108347060797"]=1,
    ["92908975354335"]=-4,["104573159846789"]=-2,["72796651173850"]=-3,
    ["87797543393819"]=-5,["99364349373891"]=-6,["71167246324478"]=-1,
}
local function shown(object)
    local current=object
    while current do
        if current:IsA("GuiObject") and not current.Visible then return false end
        if current:IsA("ScreenGui") and not current.Enabled then return false end
        current=current.Parent
    end
    return true
end
local function makeSkinDownloads(specs,deps)
    local self={entries={}}
    function self:get(asset)
        local entry=self.entries[asset]
        if entry then return entry.uri end
        entry={status="Starting image download"};self.entries[asset]=entry
        if not deps.write or not deps.register then
            entry.error="Missing writefile / getcustomasset support";return nil
        end
        deps.spawn(function()
            local ok,result=pcall(function()
                local spec=assert(specs[asset],"Unknown skin ID")
                entry.status="Downloading "..spec.name
                local data=deps.fetch(spec.url)
                assert(type(data)=="string" and #data==spec.bytes,"Wrong image download size")
                assert(data:sub(1,8)=="\137PNG\r\n\26\n","Downloaded response is not a PNG")
                entry.status="Saving "..spec.name
                assert(deps.write(spec.path,data)~=false,"Could not write image file")
                entry.status="Registering "..spec.name
                local uri=deps.register(spec.path)
                assert(type(uri)=="string" and #uri>0,"getcustomasset returned no image URI")
                return uri
            end)
            if ok then entry.uri=result;entry.status="Image downloaded"
            else entry.error=tostring(result);entry.status="Image download failed" end
        end)
        return entry.uri
    end
    function self:notice()
        for _,entry in pairs(self.entries) do if entry.error then return "Skins: "..entry.error:sub(1,160) end end
        for _,entry in pairs(self.entries) do if not entry.uri then return entry.status end end
        return nil
    end
    return self
end

local skinHttpRequest=type(request)=="function" and request or (type(http_request)=="function" and http_request)
if not skinHttpRequest and type(syn)=="table" and type(syn.request)=="function" then skinHttpRequest=syn.request end
local function fetchSkinPng(url)
    local firstError=nil
    if skinHttpRequest then
        local ok,result=pcall(skinHttpRequest,{Url=url,Method="GET",Timeout=25})
        if ok and type(result)=="table" and tonumber(result.StatusCode)==200 and type(result.Body)=="string" then return result.Body end
        firstError=ok and ("HTTP "..tostring(type(result)=="table" and result.StatusCode or "invalid response")) or tostring(result)
    end
    local ok,result=pcall(function()return game:HttpGet(url)end)
    if ok and type(result)=="string" then return result end
    error("HTTP unavailable: "..tostring(firstError or result))
end
local customSkinAsset=type(getcustomasset)=="function" and getcustomasset or (type(getsynasset)=="function" and getsynasset)
local skinDownloads=makeSkinDownloads({
    ["77696687237979"]={name="magnus-carlsen.png",url="https://raw.githubusercontent.com/hehejwkkkq1-art/wewewew/33874e3a8f34d78303c7b0284ff98ee742b0258e/magnus-carlsen.png",bytes=2131783,path="ChessHubGitHub-33874e3a8f34-magnus-carlsen.png"},
    ["85716567816234"]={name="tung-tung-tung-sahur-board.png",url="https://raw.githubusercontent.com/hehejwkkkq1-art/wewewew/33874e3a8f34d78303c7b0284ff98ee742b0258e/tung-tung-tung-sahur-board.png",bytes=2822969,path="ChessHubGitHub-33874e3a8f34-tung-tung-tung-sahur-board.png"},
},{spawn=task.spawn,fetch=fetchSkinPng,write=type(writefile)=="function" and writefile or nil,register=customSkinAsset})
local function skinUri(asset)
    return skinDownloads:get(asset) or ("rbxassetid://"..asset)
end

local nativePieces,nativeTiles,skinProbes={},{},{}
local function originalPieceImage(v)
    local entry=nativePieces[v]
    if entry and v.Image==entry.uri then return entry.original.Image end
    return v.Image
end
local function pieceTransparency(v)return v.ImageTransparency end
local function skinReady(asset)
    local uri=skinUri(asset)
    local probe=skinProbes[asset]
    if not probe then
        probe=make("ImageLabel",{Parent=gui,Name="SkinLoadProbe",Size=UDim2.fromOffset(1,1),
            Position=UDim2.fromOffset(-20,-20),BackgroundTransparency=1,Image=uri,Active=false})
        skinProbes[asset]=probe
    elseif probe.Image~=uri then probe.Image=uri end
    return probe.IsLoaded,uri
end
local function textureDimensions(asset,sourceWidth,sourceHeight)
    local probe=skinProbes[asset]
    if probe then
        local ok,size=pcall(function()return probe.ContentImageSize end)
        if ok and size and size.X and size.Y and size.X>0 and size.Y>0 then return size.X,size.Y end
    end
    -- Fallback inferred from the supplied screenshot: the local decoder used a 1024px texture.
    local factor=math.min(1,1024/math.max(sourceWidth,sourceHeight))
    return math.floor(sourceWidth*factor+.5),math.floor(sourceHeight*factor+.5)
end
local properties={"Image","ImageRectOffset","ImageRectSize","ScaleType","ImageColor3"}
local function restoreNative(v)
    local entry=nativePieces[v]
    if not entry then return end
    if v.Parent then
        local replaced=v.Image==entry.uri
        for _,name in ipairs(properties) do
            if name~="Image" or replaced then v[name]=entry.original[name] end
        end
    end
    entry.badge:Destroy();nativePieces[v]=nil
end
local function applyNative(v,piece,uri)
    local entry=nativePieces[v]
    if not entry then
        local original={}
        for _,name in ipairs(properties) do original[name]=v[name] end
        local badge=text(v,"",UDim2.new(0,1,1,-14),UDim2.new(1,-2,0,14))
        badge.ZIndex=v.ZIndex+1;badge.TextSize=10;badge.TextXAlignment=Enum.TextXAlignment.Center;badge.BackgroundTransparency=.15
        entry={original=original,badge=badge,uri=uri};nativePieces[v]=entry
    elseif v.Image~=entry.uri then
        -- The game may reuse an ImageLabel for a promotion or another piece.
        entry.original.Image=v.Image
    end
    local kind=math.abs(piece)
    local col=({[1]=0,[2]=1,[3]=2,[4]=0,[5]=4,[6]=3})[kind]
    local row=kind==1 and 0 or 1
    local width,height=textureDimensions("77696687237979",2170,725)
    local x0,x1=math.floor(col*width/8),math.floor((col+1)*width/8)
    local y0,y1=math.floor(row*height/2),math.floor((row+1)*height/2)
    entry.uri=uri;v.Image=uri
    v.ImageRectOffset=Vector2.new(x0,y0);v.ImageRectSize=Vector2.new(x1-x0,y1-y0)
    v.ScaleType=Enum.ScaleType.Fit;v.ImageColor3=Color3.fromRGB(255,255,255)
    entry.badge.Text=(piece>0 and "W " or "B ")..({"P","N","B","R","Q","K"})[kind]
    entry.badge.TextColor3=piece>0 and Color3.fromRGB(20,20,20) or Color3.fromRGB(235,235,235)
    entry.badge.BackgroundColor3=piece>0 and Color3.fromRGB(235,235,235) or Color3.fromRGB(20,20,20)
end
local function clearNativeSkins()
    for v in pairs(nativePieces) do restoreNative(v) end
    for v,image in pairs(nativeTiles) do image:Destroy();nativeTiles[v]=nil end
end
gui.Destroying:Connect(function()
    clearNativeSkins()
    for _,probe in pairs(skinProbes) do probe:Destroy() end
end)
local function updateNativeSkins()
    local pg=player:FindFirstChildOfClass("PlayerGui")
    local chess=pg and pg:FindFirstChild("ChessUI")
    local root=chess and chess:FindFirstChild("Root")
    local board=root and root:FindFirstChild("Board")
    local pieces=board and board:FindFirstChild("Pieces")
    local squares=board and board:FindFirstChild("Squares")
    local own=state.playerSide
    if own==0 and board then
        local coords=board:FindFirstChild("Coords");local bottom=nil
        if coords then for _,v in ipairs(coords:GetChildren()) do
            if v:IsA("TextLabel") and v.Text:match("^[1-8]$") and (not bottom or v.AbsolutePosition.Y>bottom.AbsolutePosition.Y) then bottom=v end
        end end
        if bottom then own=bottom.Text=="1" and 1 or -1 end
    end
    local pieceReady,pieceUri=false,nil
    if state.magnus then pieceReady,pieceUri=skinReady("77696687237979") end
    local tileReady,tileUri=false,nil
    if state.sahur then tileReady,tileUri=skinReady("85716567816234") end
    for v in pairs(nativePieces) do
        local p=imagePieces[originalPieceImage(v):match("%d+")]
        if not pieces or v.Parent~=pieces or not state.magnus or not pieceReady or not p
            or (not state.skinBoth and (p>0 and 1 or -1)~=own) then restoreNative(v) end
    end
    local count=0
    if pieces and state.magnus and pieceReady then for _,v in ipairs(pieces:GetChildren()) do
        if v:IsA("ImageLabel") or v:IsA("ImageButton") then
            local p=imagePieces[originalPieceImage(v):match("%d+")]
            if p and (state.skinBoth or (p>0 and 1 or -1)==own) then applyNative(v,p,pieceUri);count+=1 end
        end
    end end
    for v,image in pairs(nativeTiles) do
        if not squares or v.Parent~=squares or not state.sahur or not tileReady then image:Destroy();nativeTiles[v]=nil end
    end
    local tiles=0
    if squares and state.sahur and tileReady then for _,v in ipairs(squares:GetChildren()) do
        if v:IsA("GuiObject") and v.Name:match("^S%d+$") then
            local n=tonumber(v.Name:sub(2))-1
            local light=(math.floor(n/8)+n%8)%2==1
            local image=nativeTiles[v]
            if not image then
                image=make("ImageLabel",{Parent=v,Name="ChessHubBoardTexture",Size=UDim2.fromScale(1,1),
                    BackgroundTransparency=1,Active=false,ZIndex=v.ZIndex,Image=tileUri})
                nativeTiles[v]=image
            end
            local width,height=textureDimensions("85716567816234",1254,1254)
            local x0=math.floor((light and 0 or 209)*width/1254)
            local x1=math.floor((light and 209 or 418)*width/1254)
            image.Image=tileUri;image.ImageRectOffset=Vector2.new(x0,0)
            image.ImageRectSize=Vector2.new(x1-x0,math.floor(196*height/1254));tiles+=1
        end
    end end
    local notice=skinDownloads:notice()
    if not state.magnus and not state.sahur then skinNotice.Text="Custom skins: OFF"
    elseif notice then skinNotice.Text=notice
    elseif not board then skinNotice.Text="Open a chess board"
    elseif (state.magnus and not pieceReady) or (state.sahur and not tileReady) then skinNotice.Text="Downloaded PNG is not rendering: check getcustomasset"
    else
        local width,height=textureDimensions("77696687237979",2170,725)
        skinNotice.Text="Replaced "..count.." pieces / "..tiles.." squares; atlas "..width.."x"..height
    end
end
local nativeClock=0
on(game:GetService("RunService").RenderStepped,function(dt)
    nativeClock+=dt;if nativeClock<.04 then return end;nativeClock=0
    local ok,err=pcall(updateNativeSkins)
    if not ok then
        clearNativeSkins();skinNotice.Text="Direct skin error: "..tostring(err)
        warn("[ChessHub] "..tostring(err))
    end
end)

local function readBoard()
    local pg=player:FindFirstChildOfClass("PlayerGui")
    local chessUI=pg and pg:FindFirstChild("ChessUI")
    local root=chessUI and chessUI:FindFirstChild("Root")
    local board=root and root:FindFirstChild("Board")
    if not board or not shown(board) or board.AbsoluteSize.X<64 then return nil,"Open a chess board" end
    local squares,pieces,coords=board:FindFirstChild("Squares"),board:FindFirstChild("Pieces"),board:FindFirstChild("Coords")
    if not squares or not pieces or not coords then return nil,"Board structure changed" end
    local files,ranks={},{}
    for _,v in ipairs(coords:GetChildren()) do
        if v:IsA("TextLabel") then
            local f=v.Text:lower():match("^[a-h]$")
            local r=v.Text:match("^[1-8]$")
            if f then table.insert(files,{value=f:byte()-97,at=v.AbsolutePosition.X+v.AbsoluteSize.X/2}) end
            if r then table.insert(ranks,{value=tonumber(r)-1,at=v.AbsolutePosition.Y+v.AbsoluteSize.Y/2}) end
        end
    end
    if #files~=8 or #ranks~=8 then return nil,"Waiting for board coordinates" end
    local function nearest(list,value)
        local best,distance=nil,math.huge
        for _,entry in ipairs(list) do local d=math.abs(entry.at-value);if d<distance then best,distance=entry,d end end
        return best.value
    end
    local cells,position={},{}
    for r=0,7 do for f=0,7 do position[r*16+f]=0 end end
    local cellCount=0
    for _,v in ipairs(squares:GetChildren()) do
        if v:IsA("GuiObject") and v.Name:match("^S%d+$") then
            local center=v.AbsolutePosition+v.AbsoluteSize/2
            local file,rank=nearest(files,center.X),nearest(ranks,center.Y)
            local square=rank*16+file
            if cells[square] then return nil,"Board is resizing" end
            cells[square]={center=center,size=v.AbsoluteSize,object=v}
            cellCount+=1
        end
    end
    if cellCount~=64 then return nil,"Waiting for 64 squares" end
    local counts={[1]=0,[-1]=0}
    local count=0
    for _,v in ipairs(pieces:GetChildren()) do
        if (v:IsA("ImageLabel") or v:IsA("ImageButton")) and v.Visible and pieceTransparency(v)<.95 then
            local id=originalPieceImage(v):match("%d+")
            local piece=id and imagePieces[id]
            if not piece then return nil,"Unknown piece theme; use the original theme" end
            local center=v.AbsolutePosition+v.AbsoluteSize/2
            local best,distance=nil,math.huge
            for square,cell in pairs(cells) do
                local d=(cell.center-center).Magnitude
                if d<distance then best,distance=square,d end
            end
            if not best or distance>math.min(cells[best].size.X,cells[best].size.Y)*.3 then return nil,"Waiting for piece animation" end
            if position[best]~=0 then return nil,"Waiting for piece animation" end
            position[best]=piece;count+=1
            if math.abs(piece)==6 then counts[piece>0 and 1 or -1]+=1 end
        end
    end
    if counts[1]~=1 or counts[-1]~=1 or count>32 then return nil,"Waiting for a complete position" end
    local key={}
    for r=0,7 do for f=0,7 do table.insert(key,tostring(position[r*16+f])) end end
    local bottom=nearest(ranks,board.AbsolutePosition.Y+board.AbsoluteSize.Y-1)
    return {b=position,key=table.concat(key,","),cells=cells,board=board,side=state.playerSide~=0 and state.playerSide or (bottom==0 and 1 or -1)}
end

local overlay=make("Frame",{Parent=gui,Name="HintOverlay",Size=UDim2.fromScale(1,1),BackgroundTransparency=1,Active=false,ZIndex=5})
local startBox=make("Frame",{Parent=overlay,BackgroundColor3=Color3.fromRGB(255,200,70),BackgroundTransparency=.62,BorderSizePixel=0,ZIndex=5})
local endBox=make("Frame",{Parent=overlay,BackgroundColor3=Color3.fromRGB(80,220,150),BackgroundTransparency=.6,BorderSizePixel=0,ZIndex=5})
local arrow=make("Frame",{Parent=overlay,AnchorPoint=Vector2.new(.5,.5),BackgroundColor3=Color3.fromRGB(110,235,160),BorderSizePixel=0,ZIndex=6})
local wingA=arrow:Clone();wingA.Parent=overlay
local wingB=arrow:Clone();wingB.Parent=overlay
local function line(frame,a,b,width)
    local d=b-a
    frame.Position=UDim2.fromOffset((a.X+b.X)/2,(a.Y+b.Y)/2)
    frame.Size=UDim2.fromOffset(d.Magnitude,width)
    frame.Rotation=math.deg(math.atan2(d.Y,d.X))
end
local function hide()overlay.Visible=false end
local function draw(snapshot,move)
    local from,to=snapshot.cells[move.f],snapshot.cells[move.t]
    if not from or not to then hide();return end
    local origin=overlay.AbsolutePosition
    local a,b=from.center-origin,to.center-origin
    for _,pair in ipairs({{startBox,from},{endBox,to}}) do
        pair[1].Position=UDim2.fromOffset(pair[2].center.X-origin.X-pair[2].size.X/2,pair[2].center.Y-origin.Y-pair[2].size.Y/2)
        pair[1].Size=UDim2.fromOffset(pair[2].size.X,pair[2].size.Y)
    end
    local d=b-a
    if d.Magnitude<1 then hide();return end
    local unit=d.Unit
    local side=Vector2.new(-unit.Y,unit.X)
    local head=math.clamp(from.size.X*.24,9,26)
    local width=math.clamp(from.size.X*.055,3,7)
    line(arrow,a,b-unit*head*.2,width)
    line(wingA,b,b-unit*head+side*head*.55,width)
    line(wingB,b,b-unit*head-side*head*.55,width)
    overlay.Visible=true
end
hide()
local running=true
gui.Destroying:Connect(function()running=false end)
local function makeBoardTracker(Engine)
    local start = Engine.start()
    local tracker = {position = nil, lastAttempt = -math.huge, attempts = 0, recoveries = 0}
    local function sameState(a,b)
        return a.side==b.side and a.rights==b.rights and a.ep==b.ep and Engine.same(a.b,b.b)
    end
    function tracker:update(observed, now)
        if self.position and Engine.same(self.position.b,observed) then
            self.attempts=0
            return self.position,"confirmed",false
        end
        if Engine.same(start.b,observed) then
            self.position=Engine.start();self.attempts=0
            return self.position,"confirmed",true
        end
        if not self.position then return nil,"need_initial",false end
        if now-self.lastAttempt < .18 then return nil,"waiting_animation",false end
        self.lastAttempt=now;self.attempts+=1
        local trusted=self.position
        local legal=Engine.moves(trusted)
        for _,move in ipairs(legal) do
            local next=Engine.apply(trusted,move)
            if Engine.same(next.b,observed) then
                self.position=next
                if self.attempts>1 then self.recoveries+=1 end
                self.attempts=0
                return next,"confirmed",true
            end
        end
        local match=nil
        for _,a in ipairs(legal) do
            local next=Engine.apply(trusted,a)
            for _,b in ipairs(Engine.moves(next)) do
                local nextTwo=Engine.apply(next,b)
                if Engine.same(nextTwo.b,observed) then
                    if match and not sameState(match,nextTwo) then return nil,"ambiguous",false end
                    match=nextTwo
                end
            end
        end
        if match then
            self.position=match;self.attempts=0;self.recoveries+=1
            return match,"confirmed",true
        end
        -- Animation frames and unrecognised transitions must never erase trusted history.
        return nil,"waiting_animation",false
    end
    return tracker
end

-- Input-independent controller: exactly one attempt, then observed-board acknowledgement.
local function makeAutoMover(E, deps)
    local self={pending=nil,attempted=nil,enabled=false,epoch=-1,message=nil}
    function self:stop(reason)
        self.pending=nil;self.enabled=false;self.message=reason
        deps.stop(reason)
    end
    function self:poll(enabled,epoch,snapshot,now)
        if epoch~=self.epoch then
            self.epoch=epoch;self.pending=nil;self.attempted=nil;self.message=nil
        end
        self.enabled=enabled
        if not enabled then self.pending=nil;return end
        local ticket=self.pending
        if not ticket then return end
        if snapshot and E.same(snapshot.b,ticket.expected.b) then
            self.pending=nil;self.message="Move confirmed";return
        end
        -- A quick opponent may reply between two UI observations.
        if snapshot and snapshot.key~=ticket.key and ticket.sent then
            for _,reply in ipairs(E.moves(ticket.expected)) do
                if E.same(snapshot.b,E.apply(ticket.expected,reply).b) then
                    self.pending=nil;self.message="Move and reply confirmed";return
                end
            end
        end
        if now>=ticket.deadline then
            self:stop(ticket.move.prom and "Promotion not confirmed - choose a piece manually"
                or "Move not confirmed - Auto Move stopped")
        end
    end
    function self:play(snapshot,position,move,now)
        if not self.enabled or self.pending or not snapshot or not position or not move then return false end
        if position.side~=snapshot.side or not E.same(position.b,snapshot.b) then return false end
        if self.attempted==snapshot.key then return false end
        local legal=nil
        for _,candidate in ipairs(E.moves(position)) do
            if E.uci(candidate)==E.uci(move) then legal=candidate;break end
        end
        if not legal then self:stop("Calculated move is no longer legal");return false end
        local ticket={key=snapshot.key,board=snapshot.board,move=legal,
            expected=E.apply(position,legal),deadline=now+8,epoch=self.epoch,sent=false}
        self.pending=ticket;self.attempted=snapshot.key;self.message="Playing "..E.uci(legal)
        deps.spawn(function()
            local function active()
                return self.enabled and self.pending==ticket and self.epoch==ticket.epoch and deps.enabled(ticket.epoch)
            end
            local ok,sent,reason=pcall(deps.execute,snapshot,legal,active)
            if not active() then return end
            if not ok or not sent then
                self:stop(reason or (not ok and "Input failed: "..tostring(sent)) or "Input unavailable")
                return
            end
            ticket.sent=true;self.message="Waiting for move confirmation"
        end)
        return true
    end
    return self
end

local GuiService=game:GetService("GuiService")
local inputBackend=nil
local function getInputBackend()
    if inputBackend then return inputBackend end
    local ok,virtual=pcall(function()return UIS:CreateVirtualInput()end)
    if ok and virtual and pcall(function()virtual:SendMousePosition(UIS:GetMouseLocation())end) then
        inputBackend={
            move=function(p)virtual:SendMousePosition(p)end,
            button=function(p,down)virtual:SendMouseButton(p,Enum.UserInputType.MouseButton1,down,0)end,
        }
        return inputBackend
    end
    local available,manager=pcall(function()return game:GetService("VirtualInputManager")end)
    if available and manager and pcall(function()
        local p=UIS:GetMouseLocation();manager:SendMouseMoveEvent(p.X,p.Y,game)
    end) then
        inputBackend={
            move=function(p)manager:SendMouseMoveEvent(p.X,p.Y,game)end,
            button=function(p,down)manager:SendMouseButtonEvent(p.X,p.Y,0,down,game,0)end,
        }
        return inputBackend
    end
    return nil
end
local function screenPoint(object,center)
    local screen=object:FindFirstAncestorOfClass("ScreenGui")
    if not screen then error("Board has no ScreenGui") end
    if not screen.IgnoreGuiInset then center+=GuiService:GetGuiInset() end
    return Vector2.new(math.floor(center.X+.5),math.floor(center.Y+.5))
end
local function coveredByMenu(point)
    local inset=gui.IgnoreGuiInset and Vector2.zero or GuiService:GetGuiInset()
    for _,object in ipairs({window,floating}) do
        if shown(object) then
            local p,s=object.AbsolutePosition+inset,object.AbsoluteSize
            if point.X>=p.X and point.X<=p.X+s.X and point.Y>=p.Y and point.Y<=p.Y+s.Y then return true end
        end
    end
    return false
end
local function clickPoint(backend,point,active)
    if not active() then return false,"Auto Move cancelled" end
    if GuiService.MenuIsOpen or UIS:GetFocusedTextBox() then return false,"Close menus and text input, then enable Auto Move" end
    if coveredByMenu(point) then return false,"Move the ChessHub window away from the board" end
    backend.move(point)
    backend.button(point,true)
    -- Always release even if Auto Move was disabled during this wait.
    task.wait(.04)
    backend.button(point,false)
    return true
end
local function promotionButton(board,piece)
    local screen=board:FindFirstAncestorOfClass("ScreenGui")
    local match=nil
    for _,v in ipairs(screen:GetDescendants()) do
        if (v:IsA("ImageButton") or v:IsA("ImageLabel")) and shown(v) and v.ImageTransparency<.95
            and imagePieces[v.Image:match("%d+")]==piece and not v:IsDescendantOf(board:FindFirstChild("Pieces")) then
            local current=v
            local inPicker=false
            while current and current~=screen do
                if current.Name:lower():find("prom",1,true) then inPicker=true end
                current=current.Parent
            end
            local button=v:IsA("ImageButton") and v or v:FindFirstAncestorWhichIsA("GuiButton")
            if inPicker and button and button.Active and shown(button) then
                if match and match~=button then return nil end
                match=button
            end
        end
    end
    return match
end
local function executeMove(snapshot,move,active)
    local backend=getInputBackend()
    if not backend then return false,"Virtual input unavailable; hints still work" end
    local function fresh()
        if not active() then return nil end
        local live=readBoard()
        if not live or live.key~=snapshot.key or live.board~=snapshot.board or live.side~=snapshot.side then return nil end
        local input=live.board:FindFirstChild("Input")
        if not input or not input:IsA("GuiButton") or not input.Active or not shown(input) then return nil end
        return live
    end
    local live=fresh()
    if not live then return false,"Board changed or board input is inactive" end
    local cell=live.cells[move.f]
    local from=screenPoint(cell.object,cell.center)
    -- Preflight both endpoints before selecting any piece.
    local dest=live.cells[move.t]
    if coveredByMenu(from) or coveredByMenu(screenPoint(dest.object,dest.center)) then
        return false,"Move the ChessHub window away from the board"
    end
    local ok,reason=clickPoint(backend,from,active)
    if not ok then return false,reason end
    task.wait(.08)
    live=fresh()
    if not live then return false,"Position changed before destination click" end
    dest=live.cells[move.t]
    ok,reason=clickPoint(backend,screenPoint(dest.object,dest.center),active)
    if not ok then return false,reason end
    if move.prom then
        -- Only recognise a unique piece button inside an explicitly named promotion picker.
        -- Unknown layouts stop on the confirmation deadline instead of clicking guesses.
        for _=1,20 do
            task.wait(.1)
            if not active() then return true end
            local picker=promotionButton(snapshot.board,snapshot.side*move.prom)
            if picker then
                return clickPoint(backend,screenPoint(picker,picker.AbsolutePosition+picker.AbsoluteSize/2),active)
            end
        end
    end
    return true
end

local autoMover=makeAutoMover(Engine,{
    spawn=task.spawn,
    enabled=function(epoch)return running and gui.Parent~=nil and state.auto and state.autoEpoch==epoch end,
    execute=executeMove,
    stop=function(reason)setAuto(false,reason)end,
})
-- Midgame bootstrap: explicit turn, or a uniquely observed legal transition.
local function addMidgameTracking(tracker,E)
    local originalUpdate=tracker.update
    local function seed(board,side)
        local p={b=table.clone(board),side=side,rights=0,ep=-1,half=0}
        if E.check(p,-side) then return nil end
        return p
    end
    local function possibleRights(p)
        local rights=0
        if p.b[4]==6 then
            if p.b[7]==4 then rights+=1 end
            if p.b[0]==4 then rights+=2 end
        end
        if p.b[116]==-6 then
            if p.b[119]==-4 then rights+=4 end
            if p.b[112]==-4 then rights+=8 end
        end
        return rights
    end
    function tracker:attach(board,side)
        if E.same(E.start().b,board) then
            if side~=1 then return nil,"invalid_turn",false end
            self.position=E.start();self.midgame=false;self.anchor=nil
            return self.position,"confirmed",true
        end
        local p=seed(board,side)
        if not p then return nil,"invalid_turn",false end
        self.position=p;self.midgame=true;self.anchor=nil
        return p,"confirmed",true
    end
    function tracker:update(board,now)
        if not self.position and not E.same(E.start().b,board) then
            if not self.anchor then
                local white,black=seed(board,1),seed(board,-1)
                if (white~=nil)~=(black~=nil) then
                    self.position=white or black;self.midgame=true
                    return self.position,"confirmed",true
                end
                self.anchor=table.clone(board);return nil,"watch_turn",false
            end
            if E.same(self.anchor,board) then return nil,"watch_turn",false end
            if now-self.lastAttempt<.18 then return nil,"watch_turn",false end
            self.lastAttempt=now
            local match=nil
            for _,side in ipairs({1,-1}) do
                local p=seed(self.anchor,side)
                if p then
                    p.rights=possibleRights(p) -- recognition only; never recommended as known rights
                    for _,move in ipairs(E.moves(p)) do
                        local next=E.apply(p,move)
                        if E.same(next.b,board) then
                            next.rights=0
                            if match and match.side~=next.side then return nil,"ambiguous",false end
                            match=next
                        end
                    end
                end
            end
            if match then
                self.position=match;self.midgame=true;self.anchor=nil
                return match,"confirmed",true
            end
            return nil,"watch_turn",false
        end
        -- Unknown historic castling rights are used only to recognise an actual move.
        local trusted=self.position
        if self.midgame and trusted and not E.same(trusted.b,board) then
            local probe=table.clone(trusted);probe.rights=possibleRights(probe)
            for _,move in ipairs(E.moves(probe)) do
                if move.castle then
                    local next=E.apply(probe,move)
                    if E.same(next.b,board) then next.rights=0;self.position=next;return next,"confirmed",true end
                end
            end
        end
        local p,reason,changed=originalUpdate(self,board,now)
        if p and E.same(E.start().b,board) then self.midgame=false;self.anchor=nil end
        return p,reason,changed
    end
    return tracker
end

local tracker=addMidgameTracking(makeBoardTracker(Engine),Engine)
local attachEpoch=state.attachEpoch
local initial=Engine.start()
local current,lastKey,stableKey,stableCount,boardObject=nil,nil,nil,0,nil
local recommendation,searchInfo,searching,token=nil,nil,false,0
local previousEnabled=false
local function showLine(details)
    if autoMessage and not state.auto then noteText.Text=autoMessage;return end
    if details and details.pv and #details.pv>0 then
        local visible={}
        for i=1,math.min(5,#details.pv) do visible[i]=details.pv[i] end
        noteText.Text="Line: "..table.concat(visible," ")
    else noteText.Text=isTouch and "Tap CH to toggle / drag to move" or "Insert: menu / F8: stop Auto Move" end
end

task.spawn(function()
    while running and gui.Parent do
        local ok,err=pcall(function()
            if not state.hint then
                if previousEnabled then token+=1;recommendation=nil end
                previousEnabled=false;hide();showLine(nil);status.Text="Move Hint: OFF"
                -- Still track legal transitions while the visual hint is switched off.
            else previousEnabled=true end
            local snapshot,reason=readBoard()
            if snapshot and state.playerSide~=0 then snapshot.side=state.playerSide end
            if attachEpoch~=state.attachEpoch then
                attachEpoch=state.attachEpoch;tracker.position=nil;tracker.anchor=nil
                current=nil;lastKey=nil;stableKey=nil;stableCount=0;token+=1;recommendation=nil;hide()
            end
            autoMover:poll(state.auto,state.autoEpoch,snapshot,os.clock())
            local sideLabel=snapshot and (snapshot.side==1 and "White" or "Black") or "detecting"
            local confirmedTurn=current and snapshot and Engine.same(current.b,snapshot.b)
            local turnLabel=confirmedTurn and (current.side==1 and "White" or "Black") or "detecting - waiting for a move"
            detectedText.Text="Side: "..sideLabel.." / Turn: "..turnLabel
            if not snapshot then
                showLine(nil)
                token+=1;recommendation=nil;hide();stableCount=0
                if state.hint then status.Text=reason end
                return
            end
            if snapshot.board~=boardObject then
                boardObject=snapshot.board;stableKey=nil;stableCount=0;token+=1;recommendation=nil
            end
            if snapshot.key~=stableKey then
                showLine(nil)
                stableKey=snapshot.key;stableCount=1;token+=1;recommendation=nil;hide();return
            end
            stableCount+=1
            if stableCount<(current and 2 or 6) then return end
            if snapshot.key~=lastKey then
                local confirmed,syncStatus
                if not tracker.position and state.turn~=0 then
                    confirmed,syncStatus=tracker:attach(snapshot.b,state.turn)
                else confirmed,syncStatus=tracker:update(snapshot.b,os.clock()) end
                if not confirmed then
                    -- Keep the last confirmed current/lastKey while animation completes.
                    recommendation=nil;hide();showLine(nil)
                    if state.hint then
                        status.Text=syncStatus=="watch_turn" and "Detecting turn - waiting for one move"
                            or syncStatus=="invalid_turn" and "Waiting for a stable legal position"
                            or syncStatus=="need_initial" and "Waiting for a position"
                            or syncStatus=="ambiguous" and "Turn unclear - hint hidden"
                            or "Synchronising pieces - trusted history kept"
                    end
                    return
                end
                current=confirmed
                lastKey=snapshot.key;token+=1;recommendation=nil;hide()
            end
            if not state.hint then return end
            if not current then status.Text="Start a new game to establish the turn";hide();return end
            if current.side~=snapshot.side then status.Text="Waiting for your turn";showLine(nil);hide();return end
            if recommendation then
                if state.auto and not searching and searchInfo and not searchInfo.cancelled then
                    autoMover:play(snapshot,current,recommendation,os.clock())
                end
                draw(snapshot,recommendation)
                showLine(searchInfo)
                status.Text=Engine.uci(recommendation).." | depth "..tostring(searchInfo.depth)..(searching and " | improving..." or " | local search")
                if state.auto and autoMover.pending then status.Text=autoMover.message end
                return
            end
            if searching then status.Text="Analysing position...";return end
            token+=1
            local searchToken,searchPosition=token,current
            searching=true;status.Text="Analysing position..."
            task.spawn(function()
                local budget=state.budget
                local successful,best,info=pcall(Engine.search,searchPosition,budget,
                    function()return not running or not gui.Parent or token~=searchToken or not state.hint end,
                    function(partial,details)
                        if not running or not gui.Parent or token~=searchToken or not state.hint then return end
                        local live=readBoard()
                        if not live or live.key~=lastKey or live.side~=searchPosition.side then
                            hide()
                            return
                        end
                        recommendation,searchInfo=partial,details
                        draw(live,partial)
                        showLine(details)
                        status.Text=Engine.uci(partial).." | depth "..tostring(details.depth).." | improving..."
                    end)
                searching=false
                if not running or token~=searchToken then return end
                if successful then
                    recommendation,searchInfo=best,info
                    if not best then status.Text=info.cancelled and "Position changed" or "No completed analysis";hide() end
                else status.Text="Analysis failed; hint hidden";hide();warn("[ChessHub] "..tostring(best)) end
            end)
        end)
        if not ok then
            if state.auto then setAuto(false,"Board read failed - Auto Move stopped") end
            hide();status.Text="Board read failed; hint hidden";warn("[ChessHub] "..tostring(err))
        end
        task.wait(.06)
    end
end)
