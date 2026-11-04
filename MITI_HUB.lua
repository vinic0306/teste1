-- MITI HUB 0.4.0 | arquivo consolidado original; sem download de código remoto.
local factories,cache={},{}
local function requireModule(name)
 if cache[name]~=nil then return cache[name] end
 assert(factories[name],"Módulo ausente: "..name)
 local value=factories[name]();cache[name]=value;return value
end
factories["AutoFarm"]=function()
local Profiles=requireModule("Profiles")
local Settings=requireModule("Settings")
local Engine={};Engine.__index=Engine
function Engine.new(adapter,log,settings,modes)
 return setmetatable({adapter=adapter,log=log,settings=Settings.validate(settings),modes=modes,state="IDLE",generation=0},Engine)
end
function Engine:stop(reason)
 if self.adapter.cancel then self.adapter:cancel() end;self.pending=false;self.generation+=1;self.state="STOPPED";self.log:record("STOP",reason or "Parada manual")
end
function Engine:pause() if self.state=="RUNNING" then self.state="PAUSED";return true end;return false end
function Engine:resume() if self.state=="PAUSED" then self.state="RUNNING";return true end;return false end
function Engine:start(profile)
 assert(self.state~="RUNNING" and self.state~="PAUSED","Já existe rotina ativa")
 local clean=Profiles.validate(profile,self.modes)
 for _,s in ipairs(clean.steps) do assert(s.type=="wait" or self.adapter:supports(s),"Integração indisponível: "..s.type) end
 self.pending=false;self.profile=clean;self.index=1;self.round=1;self.elapsed=0;self.delay=0;self.attempt=0;self.generation+=1;self.state="RUNNING";self.log:record("START",clean.id)
end
function Engine:tick(dt)
 assert(type(dt)=="number" and dt>=0 and dt<math.huge,"Delta inválido")
 if self.state~="RUNNING" and self.state~="PAUSED" then return end
 self.elapsed+=dt
 if self.elapsed>=self.settings.maxSeconds then self:stop("Limite de tempo");return end
 if self.state=="PAUSED" then return end
 if self.pending then
  local token=self.generation;local ok,result,message=pcall(self.adapter.poll,self.adapter,dt)
  if token~=self.generation then return end
  if ok and result=="pending" then return end
  self.pending=false
  if ok and result==true then self.index+=1;self.delay=self.settings.interval;self.attempt=0;return end
  self.state="FAILED";self.log:record("FAIL",tostring(ok and message or result));return
 end
 if self.delay>0 then self.delay=math.max(0,self.delay-dt);if self.delay>0 then return end end
 if self.index>#self.profile.steps then
  self.round+=1;self.index=1
  if self.round>self.profile.repeats then self.state="COMPLETED";self.log:record("DONE",self.profile.id);return end
 end
 local step=self.profile.steps[self.index]
 if step.type=="wait" then self.delay=step.seconds;self.index+=1;return end
 local token=self.generation
 local ok,result,message=pcall(self.adapter.execute,self.adapter,step)
 if token~=self.generation or self.state~="RUNNING" then return end
 if ok and result=="pending" then self.pending=true;return end
 if ok and result==true then self.index+=1;self.attempt=0;self.delay=self.settings.interval;self.log:record("STEP",step.type)
 else
  self.attempt+=1;self.log:record("ERROR",tostring(ok and message or result))
  if self.attempt>self.settings.retries then self.state="FAILED";self.log:record("FAIL","Tentativas esgotadas")
  else self.delay=self.settings.interval;self.log:record("RETRY",self.attempt) end
 end
end
return Engine

end
factories["AutoModes"]=function()
local Modes={};Modes.__index=Modes
function Modes.new(engine,log)return setmetatable({engine=engine,log=log,queue={},active=false,serial=0},Modes)end
function Modes:enqueue(profile,priority)
 assert(type(priority)=="number" and priority%1==0 and priority>=1 and priority<=100,"Prioridade 1–100")
 self.serial+=1;table.insert(self.queue,{profile=profile,priority=priority,serial=self.serial})
 table.sort(self.queue,function(a,b)if a.priority==b.priority then return a.serial<b.serial end;return a.priority<b.priority end)
end
function Modes:start()assert(#self.queue>0,"Fila vazia");assert(self.engine.state~="RUNNING" and self.engine.state~="PAUSED","Pare a rotina antes da fila");self.active=true end
function Modes:stop()self.active=false;self.engine:stop("Fila interrompida")end
function Modes:tick(dt)
 self.engine:tick(dt)
 if not self.active or self.engine.state=="RUNNING" or self.engine.state=="PAUSED" then return end
 if #self.queue==0 then self.active=false;return end
 local item=table.remove(self.queue,1);local ok,err=pcall(self.engine.start,self.engine,item.profile)
 self.log:record(ok and "MODE" or "ERROR",ok and item.profile.id or err)
end
return Modes

end
factories["Diagnostics"]=function()
local Diagnostics = {}; Diagnostics.__index=Diagnostics
function Diagnostics.new(limit) return setmetatable({limit=limit or 200,entries={},sequence=0},Diagnostics) end
function Diagnostics:record(level,message)
 self.sequence+=1
 table.insert(self.entries,{sequence=self.sequence,level=level,message=string.sub(tostring(message),1,500)})
 if #self.entries>self.limit then table.remove(self.entries,1) end
end
function Diagnostics:export()
 local rows={};for _,e in ipairs(self.entries) do table.insert(rows,string.format("%d [%s] %s",e.sequence,e.level,e.message)) end
 return table.concat(rows,"\n")
end
return Diagnostics

end
factories["GameAdapter"]=function()
local Adapter={};Adapter.__index=Adapter
function Adapter.new(teleport)return setmetatable({teleport=teleport,actions={}},Adapter)end
function Adapter:register(name,handler)assert(type(handler)=="function" and not self.actions[name],"Ação inválida");self.actions[name]=handler end
function Adapter:supports(step)return (step.type=="navigate" and self.teleport.enabled()) or (step.type=="action" and self.actions[step.name]~=nil)end
function Adapter:execute(step)
 if step.type=="navigate" then return self.teleport:begin(step.target) end
 local action=self.actions[step.name];if not action then return false,"Ação específica do jogo não integrada" end
 return action(step)
end
function Adapter:poll(dt)return self.teleport:poll(dt)end
function Adapter:cancel()self.teleport:cancel()end
return Adapter

end
factories["Json"]=function()
-- Codec de configuração. null é rejeitado; arrays vazios são preservados como [].
local Json={}
local bs=string.char(92)
local escapes={['"']='"',[bs]=bs,['/']='/',b=string.char(8),f=string.char(12),n=string.char(10),r=string.char(13),t=string.char(9)}
function Json.decode(text)
 assert(type(text)=='string' and #text<=262144,'JSON excede 256 KB')
 local i=1
 local function ws()while true do local c=text:byte(i);if c~=32 and c~=9 and c~=10 and c~=13 then break end;i+=1 end end
 local function str()
  assert(text:sub(i,i)=='"','String esperada');i+=1;local out={}
  while i<=#text do
   local c=text:sub(i,i);i+=1
   if c=='"' then return table.concat(out) end
   if c==bs then
    c=text:sub(i,i);i+=1
    if c=='u' then
     local hex=text:sub(i,i+3);assert(#hex==4 and hex:match('^%x+$'),'Unicode inválido');i+=4;local cp=tonumber(hex,16)
     if cp>=0xD800 and cp<=0xDBFF then
      assert(text:sub(i,i+1)==bs..'u','Par Unicode ausente');i+=2;hex=text:sub(i,i+3);assert(#hex==4 and hex:match('^%x+$'),'Unicode inválido');i+=4
      local low=tonumber(hex,16);assert(low>=0xDC00 and low<=0xDFFF,'Par Unicode inválido');cp=0x10000+(cp-0xD800)*1024+low-0xDC00
     else assert(cp<0xDC00 or cp>0xDFFF,'Unicode inválido') end
     table.insert(out,utf8.char(cp))
    else assert(escapes[c],'Escape inválido');table.insert(out,escapes[c]) end
   else assert(c:byte()>=32,'Caractere de controle');table.insert(out,c) end
  end
  error('String não terminada')
 end
 local parse
 parse=function(depth)
  assert(depth<=16,'JSON profundo demais');ws();local c=text:sub(i,i)
  if c=='"' then return str() end
  if c=='{' or c=='[' then
   local object=c=='{';local close=object and '}' or ']';i+=1;ws();local result={}
   if text:sub(i,i)==close then i+=1;return result end
   while true do
    ws();local key=object and str() or #result+1
    if object then ws();assert(text:sub(i,i)==':','Dois pontos esperados');i+=1;assert(result[key]==nil,'Chave duplicada') end
    result[key]=parse(depth+1);ws();c=text:sub(i,i);i+=1
    if c==close then return result end
    assert(c==',','Separador inválido')
   end
  end
  for word,value in pairs({['true']=true,['false']=false}) do if text:sub(i,i+#word-1)==word then i+=#word;return value end end
  local start=i
  if text:sub(i,i)=='-' then i+=1 end
  assert(text:sub(i,i):match('%d'),'Número esperado')
  if text:sub(i,i)=='0' then i+=1;assert(not text:sub(i,i):match('%d'),'Zero inicial inválido')
  else repeat i+=1 until not text:sub(i,i):match('%d') end
  if text:sub(i,i)=='.' then i+=1;assert(text:sub(i,i):match('%d'),'Fração inválida');repeat i+=1 until not text:sub(i,i):match('%d') end
  c=text:sub(i,i)
  if c=='e' or c=='E' then
   i+=1;c=text:sub(i,i);if c=='+' or c=='-' then i+=1 end
   assert(text:sub(i,i):match('%d'),'Expoente inválido');repeat i+=1 until not text:sub(i,i):match('%d')
  end
  local number=tonumber(text:sub(start,i-1));assert(number and number==number and math.abs(number)<math.huge,'Número inválido');return number
 end
 local result=parse(0);ws();assert(i>#text,'Conteúdo após JSON');return result
end
local function quote(s)
 local out={'"'}
 for i=1,#s do
  local c=s:sub(i,i)
  if c=='"' or c==bs then table.insert(out,bs..c)
  elseif c:byte()<32 then table.insert(out,bs..string.format('u%04x',c:byte()))
  else table.insert(out,c) end
 end
 table.insert(out,'"');return table.concat(out)
end
function Json.encode(value)
 local seen={}
 local function enc(v,depth)
  assert(depth<=16,'JSON profundo demais')
  if type(v)=='string' then return quote(v) end
  if type(v)=='boolean' then return tostring(v) end
  if type(v)=='number' then assert(v==v and math.abs(v)<math.huge,'Número inválido');return tostring(v) end
  assert(type(v)=='table' and not seen[v],'Tipo/ciclo inválido');seen[v]=true
  local count=0;local array=true
  for k in pairs(v) do count+=1;if type(k)~='number' or k%1~=0 or k<1 then array=false end end
  if count~=#v then array=false end
  local out={}
  if array then for _,item in ipairs(v) do table.insert(out,enc(item,depth+1)) end
  else local keys={};for k in pairs(v) do assert(type(k)=='string','Chave deve ser texto');table.insert(keys,k) end;table.sort(keys)
   for _,k in ipairs(keys) do table.insert(out,quote(k)..':'..enc(v[k],depth+1)) end
  end
  seen[v]=nil;return (array and '[' or '{')..table.concat(out,',')..(array and ']' or '}')
 end
 local text=enc(value,0);assert(#text<=262144,'JSON excede 256 KB');return text
end
return Json

end
factories["ModeRegistry"]=function()
local Modes={};Modes.__index=Modes
function Modes.new() local self=setmetatable({entries={}},Modes);self:register("npc","NPCs");self:register("farm","Farm");self:register("mode","Modos");return self end
function Modes:register(id,label) assert(type(id)=="string" and #id>0 and not self.entries[id],"Modo inválido/duplicado");self.entries[id]=label end
function Modes:has(id) return self.entries[id]~=nil end
return Modes

end
factories["NPCManager"]=function()
local Manager={};Manager.__index=Manager
function Manager.new(provider) return setmetatable({provider=provider,records={},byId={},route={}},Manager) end
function Manager:refresh()
 local records=self.provider:scan();local byId={}
 for _,r in ipairs(records) do
  assert(type(r.id)=="string" and type(r.name)=="string" and type(r.map)=="string","Registro NPC inválido")
  assert(not byId[r.id],"ID NPC duplicado");byId[r.id]=r
 end
 self.records=records;self.byId=byId
 local route={};for _,id in ipairs(self.route) do if byId[id] then table.insert(route,id) end end;self.route=route
 return records
end
function Manager:filter(name,map)
 local result={};name=string.lower(name or "");map=string.lower(map or "")
 for _,r in ipairs(self.records) do if string.find(string.lower(r.name),name,1,true) and string.find(string.lower(r.map),map,1,true) then table.insert(result,r) end end
 return result
end
function Manager:toggle(id)
 assert(self.byId[id],"NPC indisponível")
 for i,v in ipairs(self.route) do if v==id then table.remove(self.route,i);return false end end
 table.insert(self.route,id);return true
end
function Manager:move(index,delta)
 local other=index+delta;if index<1 or index>#self.route or other<1 or other>#self.route then return false end
 self.route[index],self.route[other]=self.route[other],self.route[index];return true
end
function Manager:routeSteps()
 local steps={};for _,id in ipairs(self.route) do table.insert(steps,{type="navigate",target=id}) end;return steps
end
return Manager

end
factories["Persistence"]=function()
local Json=requireModule("Json")
local Settings=requireModule("Settings")
local Profiles=requireModule("Profiles")
local Persistence={};Persistence.__index=Persistence
function Persistence.new(api,modes)return setmetatable({api=api or {},modes=modes,path="miti_hub_v04.json"},Persistence)end
function Persistence:decode(text)
 local data=Json.decode(text);assert(data.version==1 and type(data.profiles)=="table","Arquivo de preferências inválido")
 for key in pairs(data)do assert(key=="version" or key=="settings" or key=="profiles","Campo inesperado no arquivo")end
 assert(#data.profiles<=100,"Máximo de 100 perfis persistidos")
 local count=0;for key in pairs(data.profiles)do count+=1;assert(type(key)=="number" and key%1==0 and key>=1 and key<=#data.profiles,"Lista de perfis inválida")end;assert(count==#data.profiles,"Lista esparsa")
 local settings=Settings.validate(data.settings);local list={};local seen={}
 for _,p in ipairs(data.profiles)do local valid=Profiles.validate(p,self.modes);assert(not seen[valid.id],"Perfil duplicado");seen[valid.id]=true;table.insert(list,valid)end
 return {version=1,settings=settings,profiles=list}
end
function Persistence:load()
 if type(self.api.read)~="function" then return nil,"readfile indisponível; use JSON manual" end
 local ok,text=pcall(self.api.read,self.path);if not ok then return nil,"Nenhuma configuração legível" end
 local valid,data=pcall(self.decode,self,text);if not valid then return nil,"Configuração rejeitada: "..tostring(data) end
 return data
end
function Persistence:save(settings,profiles)
 if type(self.api.read)~="function" or type(self.api.write)~="function" then return false,"readfile/writefile indisponíveis; use exportação JSON" end
 local text=Json.encode(self:decode(Json.encode({version=1,settings=settings,profiles=profiles})))
 local oldOk,old=pcall(self.api.read,self.path)
 local ok,err=pcall(function()
  if oldOk and type(old)=="string" and #old<=262144 then self.api.write(self.path..".bak",old) end
  self.api.write(self.path,text);assert(self.api.read(self.path)==text,"Conteúdo gravado não confere")
 end)
 return ok,ok and "Configuração salva e relida" or tostring(err)
end
return Persistence

end
factories["Profiles"]=function()
local Json=requireModule("Json")
local Profiles={};Profiles.__index=Profiles
local function onlyKeys(value,allowed)
 for key in pairs(value) do assert(allowed[key],"Campo não permitido: "..tostring(key)) end
end
local function number(v,lo,hi,integer)
 return type(v)=="number" and v==v and v>=lo and v<=hi and (not integer or v%1==0)
end
function Profiles.validate(p,modes)
 assert(type(p)=="table" and p.version==1,"Versão de perfil inválida")
 onlyKeys(p,{version=true,id=true,name=true,map=true,mode=true,repeats=true,steps=true})
 for _,k in ipairs({"id","name","map","mode"}) do assert(type(p[k])=="string" and #p[k]>0 and #p[k]<=100,"Campo inválido: "..k) end
 assert(not modes or modes:has(p.mode),"Modo não registrado")
 assert(number(p.repeats,1,100,true),"Repetições inválidas")
 assert(type(p.steps)=="table" and #p.steps>=1 and #p.steps<=200,"Passos inválidos")
 local keys=0;for k in pairs(p.steps) do keys+=1;assert(type(k)=="number" and k%1==0 and k>=1 and k<=#p.steps,"Array de passos inválido") end;assert(keys==#p.steps,"Array esparso")
 local duration=0
 for _,s in ipairs(p.steps) do
  assert(type(s)=="table","Passo inválido")
  if s.type=="wait" then onlyKeys(s,{type=true,seconds=true});assert(number(s.seconds,0.05,60,false),"Espera inválida");duration+=s.seconds
  elseif s.type=="navigate" then onlyKeys(s,{type=true,target=true});assert(type(s.target)=="string" and #s.target>0 and #s.target<=100,"Destino inválido")
  elseif s.type=="action" then onlyKeys(s,{type=true,name=true});assert(type(s.name)=="string" and s.name:match('^[%w_]+$') and #s.name<=60,"Ação inválida")
  else error("Tipo de passo não suportado") end
 end
 assert(duration*p.repeats<=1800,"Duração excede limite")
 return Json.decode(Json.encode(p))
end
function Profiles.new(modes) return setmetatable({modes=modes,items={}},Profiles) end
function Profiles:save(p) local clean=Profiles.validate(p,self.modes);self.items[clean.id]=clean;return clean end
function Profiles:import(text) return self:save(Json.decode(text)) end
function Profiles:export(id) assert(self.items[id],"Perfil ausente");return Json.encode(self.items[id]) end
function Profiles:remove(id) self.items[id]=nil end
function Profiles:list(mode) local list={};for _,p in pairs(self.items) do if not mode or p.mode==mode then table.insert(list,Profiles.validate(p,self.modes)) end end;table.sort(list,function(a,b)return a.id<b.id end);return list end
return Profiles

end
factories["RobloxProvider"]=function()
-- Somente observa modelos replicados no contexto atual. Nenhum RemoteEvent é chamado.
local Provider={};Provider.__index=Provider
function Provider.new(workspace,players,sessionId)
 return setmetatable({workspace=workspace,players=players,ids=setmetatable({},{__mode="k"}),nextId=0,sessionId=sessionId or "session"},Provider)
end
function Provider:scan()
 local records={}
 for _,model in ipairs(self.workspace:GetDescendants()) do
  if model:IsA("Model") then
   local isPlayer=false
   for _,p in ipairs(self.players:GetPlayers()) do
    local c=p.Character
    if c and (model==c or model:IsDescendantOf(c) or c:IsDescendantOf(model)) then isPlayer=true;break end
   end
   local hum=model:FindFirstChildOfClass("Humanoid")
   local name=string.lower(model.Name)
   local hinted=string.find(name,"npc",1,true) or string.find(name,"quest",1,true) or string.find(name,"merchant",1,true)
   local root=model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
   if not isPlayer and (hum or hinted or model:GetAttribute("MitiNpc")==true) and root and root:IsA("BasePart") then
    if not self.ids[model] then self.nextId+=1;self.ids[model]=self.sessionId.."-"..self.nextId end
    local map=model:GetAttribute("MitiMap")
    table.insert(records,{id=self.ids[model],name=model.Name,map=type(map)=="string" and map or model.Parent.Name,instance=model,position=root.Position,evidence=hum and "Humanoid" or "name_or_attribute",confirmed=false})
   end
  end
 end
 table.sort(records,function(a,b)if a.name==b.name then return a.id<b.id end;return a.name<b.name end)
 return records
end
return Provider

end
factories["RobloxTransport"]=function()
local Transport={};Transport.__index=Transport
function Transport.new(player)return setmetatable({player=player},Transport)end
function Transport:move(npc)
 local character=self.player.Character;assert(character and character.Parent,"Personagem indisponível")
 local humanoid=character:FindFirstChildOfClass("Humanoid");assert(humanoid and humanoid.Health>0,"Personagem sem vida")
 local root=character:FindFirstChild("HumanoidRootPart");assert(root and root:IsA("BasePart"),"Raiz ausente")
 local model=npc.instance;assert(model and model:IsDescendantOf(workspace),"NPC removido/não carregado")
 local target=model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
 assert(target and target:IsA("BasePart"),"NPC sem posição")
 local destination=target.CFrame:PointToWorldSpace(Vector3.new(0,3,-6))
 local facing=CFrame.lookAt(destination,target.Position)
 character:PivotTo(facing*root.CFrame:ToObjectSpace(character:GetPivot()))
 root.AssemblyLinearVelocity=Vector3.zero;root.AssemblyAngularVelocity=Vector3.zero
 return {character=character,root=root,position=destination}
end
function Transport:distance(ticket)
 assert(self.player.Character==ticket.character and ticket.root.Parent,"Personagem mudou")
 return (ticket.root.Position-ticket.position).Magnitude
end
return Transport

end
factories["Settings"]=function()
local Settings = {}
Settings.defaults = { version = 1, interval = 0.25, retries = 0, maxSeconds = 1800, experimentalTeleport = false }
function Settings.validate(s)
 assert(type(s)=="table" and s.version==1,"Configuração versão 1 obrigatória")
 for key in pairs(s) do assert(Settings.defaults[key]~=nil,"Configuração desconhecida: "..tostring(key)) end
 for key,limits in pairs({interval={0.05,60}, retries={0,3}, maxSeconds={1,1800}}) do
  local n=s[key];assert(type(n)=="number" and n==n and n>=limits[1] and n<=limits[2],"Configuração inválida: "..key)
 end
 if s.experimentalTeleport==nil then s.experimentalTeleport=false end
 assert(type(s.experimentalTeleport)=="boolean","experimentalTeleport deve ser booleano")
 assert(s.retries%1==0,"Retries deve ser inteiro")
 return table.clone(s)
end
return Settings

end
factories["Teleport"]=function()
-- Uma tentativa local; sem anticheat bypass, sem repetir correções do servidor.
local Teleport={};Teleport.__index=Teleport
function Teleport.new(manager,transport,log,enabled)
 return setmetatable({manager=manager,transport=transport,log=log,enabled=enabled,pending=nil},Teleport)
end
function Teleport:begin(id)
 if self.pending then return false,"Deslocamento já em verificação" end
 if not self.enabled() then return false,"Ative experimentalTeleport em Settings" end
 local npc=self.manager.byId[id];if not npc then return false,"NPC indisponível: "..id end
 local ok,ticket=pcall(self.transport.move,self.transport,npc)
 if not ok then self.log:record("ERROR",ticket);return false,tostring(ticket) end
 self.pending={ticket=ticket,elapsed=0,id=id}
 self.log:record("EXPERIMENTAL","Posição local aplicada: "..id.."; verificando por 2 segundos")
 return "pending"
end
function Teleport:poll(dt)
 local p=self.pending;if not p then return false,"Verificação cancelada" end
 p.elapsed+=dt
 local ok,distance=pcall(self.transport.distance,self.transport,p.ticket)
 if not ok or type(distance)~="number" or distance~=distance or distance>8 then
  self.pending=nil;local reason=ok and "Posição divergente ou corrigida" or tostring(distance);self.log:record("ERROR",reason);return false,reason
 end
 if p.elapsed<2 then return "pending" end
 self.pending=nil;self.log:record("LOCAL_ONLY","Posição local observada por 2 segundos; sem prova de aceitação do servidor")
 return true,"LOCAL_POSITION_OBSERVED"
end
function Teleport:cancel()self.pending=nil end
return Teleport

end
factories["UI"]=function()
local UI={}
local function create(kind,parent,props)
 local object=Instance.new(kind)
 for key,value in pairs(props or {}) do object[key]=value end
 object.Parent=parent;return object
end
local function round(object)create("UICorner",object,{CornerRadius=UDim.new(0,8)})end
function UI.mount(parent,ctx)
 local background=Color3.fromRGB(14,18,29)
local card=Color3.fromRGB(26,35,51)
local accent=Color3.fromRGB(70,176,235)

 local old=parent:FindFirstChild("MITI_HUB_MODULAR");if old then old:Destroy() end
 local self={connections={},closed=false,tab="NPCs",draft="",closedCallback=nil}
 local gui=create("ScreenGui",parent,{Name="MITI_HUB_MODULAR",ResetOnSpawn=false,ZIndexBehavior=Enum.ZIndexBehavior.Sibling})
 local frame=create("Frame",gui,{Size=UDim2.fromOffset(360,550),Position=UDim2.new(0.5,-180,0.5,-275),BackgroundColor3=background,BorderSizePixel=0});round(frame)
 local scale=create("UIScale",frame,{Scale=1})
 local status=create("TextLabel",frame,{Position=UDim2.fromOffset(14,45),Size=UDim2.new(1,-28,0,26),BackgroundTransparency=1,TextColor3=accent,TextSize=12,Font=Enum.Font.Gotham,Text="IDLE · teleporte local experimental",TextXAlignment=Enum.TextXAlignment.Left})
 local function button(parent,text,action)
  local b=create("TextButton",parent,{Size=UDim2.new(1,-8,0,36),BackgroundColor3=card,TextColor3=Color3.new(1,1,1),Text=text,TextSize=12,Font=Enum.Font.Gotham,BorderSizePixel=0});round(b)
  b.Activated:Connect(function()
   local ok,err=pcall(action)
   if not ok then ctx.log:record("ERROR",err);status.Text=tostring(err) end
  end)
  return b
 end
 local title=create("TextLabel",frame,{Position=UDim2.fromOffset(14,9),Size=UDim2.fromOffset(230,32),Text="MITI HUB  /  0.4",TextColor3=Color3.new(1,1,1),TextSize=19,Font=Enum.Font.GothamBold,BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,Active=true})
 local mini=button(frame,"−",function()frame.Visible=false;self.icon.Visible=true end);mini.Size=UDim2.fromOffset(36,30);mini.Position=UDim2.fromOffset(270,10)
 local close=button(frame,"×",function()gui:Destroy()end);close.Size=UDim2.fromOffset(36,30);close.Position=UDim2.fromOffset(312,10)
 self.icon=button(gui,"MITI",function()frame.Visible=true;self.icon.Visible=false end);self.icon.Size=UDim2.fromOffset(60,44);self.icon.Position=UDim2.fromOffset(12,90);self.icon.Visible=false
 local tabs=create("Frame",frame,{Position=UDim2.fromOffset(12,78),Size=UDim2.fromOffset(336,36),BackgroundTransparency=1})
 local body=create("ScrollingFrame",frame,{Position=UDim2.fromOffset(12,122),Size=UDim2.fromOffset(336,322),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=4,CanvasSize=UDim2.new(),AutomaticCanvasSize=Enum.AutomaticSize.Y})
 create("UIListLayout",body,{Padding=UDim.new(0,7),SortOrder=Enum.SortOrder.LayoutOrder})
 local function text(message,height)
  return create("TextLabel",body,{Size=UDim2.new(1,-8,0,height or 38),BackgroundTransparency=1,TextColor3=Color3.fromRGB(185,201,222),Text=message,TextSize=12,TextWrapped=true,Font=Enum.Font.Gotham,TextXAlignment=Enum.TextXAlignment.Left})
 end
 local function box(value,height,placeholder)
  local host=body
  if (height or 36)>40 then
   host=create("ScrollingFrame",body,{Size=UDim2.new(1,-8,0,height),BackgroundColor3=card,BorderSizePixel=0,ScrollBarThickness=4,CanvasSize=UDim2.new(),AutomaticCanvasSize=Enum.AutomaticSize.Y})
   round(host)
  end
  local b=create("TextBox",host,{Size=UDim2.new(1,-8,0,height or 36),BackgroundColor3=card,TextColor3=Color3.new(1,1,1),Text=value,PlaceholderText=placeholder or "",PlaceholderColor3=Color3.fromRGB(160,170,190),TextSize=12,Font=Enum.Font.Code,ClearTextOnFocus=false,MultiLine=(height or 36)>40,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top});round(b);if host~=body then b.AutomaticSize=Enum.AutomaticSize.Y end;return b
 end
 local function capture()if self.editor then self.draft=self.editor.Text end end
 local render
 local function loadProfile(p)
  capture();self.draft=ctx.json.encode(p);self.profileId=p.id;render()
 end
 render=function()
  self.editor=nil
  for _,child in ipairs(body:GetChildren()) do if not child:IsA("UIListLayout") then child:Destroy() end end
  body.CanvasPosition=Vector2.zero
  if self.tab=="NPCs" then
   text("Candidatos carregados, não confirmados. Selecione para montar a ordem da rota.",42)
   local name=box(self.nameFilter or "",32,"Filtrar nome")
   local map=box(self.mapFilter or "",32,"Filtrar mapa")
   button(body,"Aplicar filtros / atualizar",function()self.nameFilter=name.Text;self.mapFilter=map.Text;ctx.manager:refresh();render()end)
   local records=ctx.manager:filter(self.nameFilter,self.mapFilter)
   if #records==0 then text("Nenhum candidato disponível. Atualize a lista.") end
   for _,npc in ipairs(records) do
    local selected=table.find(ctx.manager.route,npc.id)~=nil
    button(body,(selected and "✓ " or "+ ")..npc.name.." · "..npc.map.." ["..npc.id.."]",function()ctx.manager:toggle(npc.id);render()end)
    button(body,"Ir experimental: "..npc.name,function()ctx.runProfile({version=1,id="manual-target",name="Destino manual",map=npc.map,mode="npc",repeats=1,steps={{type="navigate",target=npc.id}}})end)
   end
   text("Ordem da rota (IDs válidos apenas nesta sessão)")
   for i,id in ipairs(ctx.manager.route) do
    text(i..". "..id,24)
    button(body,"↑ "..id,function()ctx.manager:move(i,-1);render()end)
    button(body,"↓ "..id,function()ctx.manager:move(i,1);render()end)
   end
   button(body,"Criar perfil da rota",function()
    local p={version=1,id="npc-route",name="Rota selecionada",map=self.mapFilter~="" and self.mapFilter or "Sessão",mode="npc",repeats=1,steps=ctx.manager:routeSteps()}
    if not p.map then p.map="Sessão" end
    ctx.profiles:save(p);self.tab="Modos";loadProfile(p)
   end)
   text("Teleporte é local e experimental. Ative experimentalTeleport em Settings. Não garante desbloqueio de mapas.",44)
  elseif self.tab=="Farm" or self.tab=="Modos" then
   text("Perfis locais à sessão. Exporte JSON para preservar. Não há farm pronto.",42)
   for _,p in ipairs(ctx.profiles:list(self.tab=="Farm" and "farm" or nil)) do
    button(body,p.name.." · "..p.map.." / "..p.mode,function()loadProfile(p)end)
   end
   if self.draft=="" then self.draft=ctx.json.encode({version=1,id="new-profile",name="Nova rotina",map="Local",mode="farm",repeats=1,steps={{type="wait",seconds=1}}}) end
   self.editor=box(self.draft,160,"Perfil JSON")
   button(body,"Importar / salvar JSON do editor",function()capture();local p=ctx.profiles:import(self.draft);self.profileId=p.id;ctx.log:record("INFO","Perfil salvo: "..p.id);render()end)
   button(body,"Exportar perfil selecionado ao editor",function()assert(self.profileId,"Selecione um perfil");self.draft=ctx.profiles:export(self.profileId);render()end)
   button(body,"Excluir perfil selecionado",function()assert(self.profileId,"Selecione um perfil");ctx.profiles:remove(self.profileId);self.profileId=nil;self.draft="";render()end)
   text("wait: seconds • navigate: target • action: name. Repetições: repeats. Ações exigem integração registrada.",52)
     if self.tab=="Modos" then
    local priority=box("10",32,"Prioridade 1–100; menor primeiro")
    button(body,"Adicionar rascunho à fila",function()capture();ctx.scheduler:enqueue(ctx.profiles:import(self.draft),tonumber(priority.Text));render()end)
    for _,item in ipairs(ctx.scheduler.queue)do text(tostring(item.priority).." · "..item.profile.name,28)end
    button(body,"Iniciar fila de modos",function()ctx.scheduler:start()end)
    button(body,"Limpar fila",function()assert(not ctx.scheduler.active,"Pare a fila primeiro");ctx.scheduler.queue={};render()end)
   end
  else
   text("Preferências da sessão. Copie o JSON para guardar. Sem autenticação/licença comercial.",42)
   local config=box(ctx.json.encode(ctx.settings),100,"Configurações JSON")
   button(body,"Aplicar configurações",function()
    assert(ctx.engine.state~="RUNNING" and ctx.engine.state~="PAUSED","Pare a rotina primeiro")
    ctx.settings=ctx.settingsModule.validate(ctx.json.decode(config.Text));ctx.engine.settings=table.clone(ctx.settings);ctx.log:record("INFO","Configuração aplicada");render()
   end)
   button(body,"Salvar configurações e perfis em arquivo",function()
    local ok,message=ctx.storage:save(ctx.engine.settings,ctx.profiles:list());ctx.log:record(ok and "INFO" or "ERROR",message);status.Text=message
   end)
   text("experimentalTeleport=true habilita tentativa local. Persistência requer readfile/writefile. Sem farm de combate integrado.",56)
   box(ctx.log:export(),180,"Diagnósticos")
   button(body,"Atualizar diagnósticos",function()render()end)
  end
 end
 for i,name in ipairs({"NPCs","Farm","Modos","Settings"}) do
  local b=button(tabs,name,function()capture();self.tab=name;render()end);b.Size=UDim2.fromOffset(80,34);b.Position=UDim2.fromOffset((i-1)*85,0)
 end
 local controls=create("Frame",frame,{Position=UDim2.fromOffset(12,454),Size=UDim2.fromOffset(336,36),BackgroundTransparency=1})
 local start=button(controls,"Iniciar",function()assert(self.tab=="Farm" or self.tab=="Modos","Abra um perfil em Farm ou Modos para iniciar");capture();local p=ctx.profiles:import(self.draft);ctx.runProfile(p)end);start.Size=UDim2.fromOffset(105,36)
 local pause=button(controls,"Pausar/seguir",function()if ctx.engine.state=="PAUSED" then ctx.engine:resume() else ctx.engine:pause() end end);pause.Size=UDim2.fromOffset(110,36);pause.Position=UDim2.fromOffset(110,0)
 local stop=button(controls,"PARAR",function()ctx.scheduler:stop()end);stop.Size=UDim2.fromOffset(108,36);stop.Position=UDim2.fromOffset(226,0);stop.BackgroundColor3=Color3.fromRGB(150,48,60)
 create("TextLabel",frame,{Position=UDim2.fromOffset(12,500),Size=UDim2.fromOffset(336,36),Text="MITI HUB • teleporte local experimental",TextSize=11,TextColor3=accent,BackgroundTransparency=1,TextWrapped=true})
 local function fit()
  local camera=workspace.CurrentCamera;if not camera then return end
  local viewport=camera.ViewportSize
  scale.Scale=math.min(1,math.max(0.1,(viewport.X-24)/360),math.max(0.1,(viewport.Y-70)/550))
  local position=frame.AbsolutePosition
  frame.Position=UDim2.fromOffset(math.clamp(position.X,0,math.max(0,viewport.X-frame.AbsoluteSize.X)),math.clamp(position.Y,0,math.max(0,viewport.Y-frame.AbsoluteSize.Y-50)))
 end
 local cameraConnection
 local function watchCamera()
  if cameraConnection then cameraConnection:Disconnect() end
  if workspace.CurrentCamera then cameraConnection=workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit) end
  fit()
 end
 local input=game:GetService("UserInputService")
 local pointer,origin,startPos
 title.InputBegan:Connect(function(event)
  if event.UserInputType==Enum.UserInputType.MouseButton1 or event.UserInputType==Enum.UserInputType.Touch then pointer=event;origin=event.Position;startPos=frame.Position end
 end)
 table.insert(self.connections,input.InputChanged:Connect(function(event)
  if pointer and (event==pointer or (pointer.UserInputType==Enum.UserInputType.MouseButton1 and event.UserInputType==Enum.UserInputType.MouseMovement)) then
   local delta=event.Position-origin;frame.Position=UDim2.new(startPos.X.Scale,startPos.X.Offset+delta.X,startPos.Y.Scale,startPos.Y.Offset+delta.Y)
  end
 end))
 table.insert(self.connections,input.InputEnded:Connect(function(event)if event==pointer then pointer=nil;fit()end end))
 table.insert(self.connections,workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera))
 gui.Destroying:Connect(function()
  self.closed=true;for _,connection in ipairs(self.connections) do connection:Disconnect() end
  if cameraConnection then cameraConnection:Disconnect() end
  if self.closedCallback then self.closedCallback() end
 end)
 function self:onClose(callback)self.closedCallback=callback;if self.closed then callback() end end
 local lastState
 function self:updateState(state)if state~=lastState and not self.closed then lastState=state;status.Text=state.." · teleporte local experimental" end end
 watchCamera()
 local ok,err=pcall(ctx.manager.refresh,ctx.manager);if not ok then ctx.log:record("ERROR",err) end
 render();return self
end
return UI

end
factories["main"]=function()
-- Entrada modular. Para carregar tudo de uma vez, utilize MITI_HUB.lua.
local Main={}
local Diagnostics=requireModule("Diagnostics")
local Settings=requireModule("Settings")
local Profiles=requireModule("Profiles")
local Json=requireModule("Json")
local NPCManager=requireModule("NPCManager")
local RobloxProvider=requireModule("RobloxProvider")
local Teleport=requireModule("Teleport")
local RobloxTransport=requireModule("RobloxTransport")
local AutoFarm=requireModule("AutoFarm")
local AutoModes=requireModule("AutoModes")
local ModeRegistry=requireModule("ModeRegistry")
local GameAdapter=requireModule("GameAdapter")
local Persistence=requireModule("Persistence")
local UI=requireModule("UI")
Main.modules={Settings=Settings,Profiles=Profiles,Json=Json,NPCManager=NPCManager,Teleport=Teleport,AutoFarm=AutoFarm,AutoModes=AutoModes,Persistence=Persistence,Diagnostics=Diagnostics,ModeRegistry=ModeRegistry}
function Main.start()
 assert(game and game.GetService,"MITI HUB exige cliente Roblox com APIs Luau disponíveis")
 local players=game:GetService("Players");local player=players.LocalPlayer;assert(player,"LocalPlayer indisponível")
 local log=Diagnostics.new(200);local modes=ModeRegistry.new();local profiles=Profiles.new(modes)
 local settings=table.clone(Settings.defaults)
 local storage=Persistence.new({read=readfile,write=writefile},modes)
 local saved,reason=storage:load()
 if saved then settings=saved.settings;for _,p in ipairs(saved.profiles)do profiles:save(p)end else log:record("INFO",reason)end
 if #profiles:list()==0 then profiles:save({version=1,id="wait-test",name="Teste de espera",map="Local",mode="farm",repeats=1,steps={{type="wait",seconds=1}}})end
 local manager=NPCManager.new(RobloxProvider.new(workspace,players,game:GetService("HttpService"):GenerateGUID(false)))
 local engine
 local teleport=Teleport.new(manager,RobloxTransport.new(player),log,function()return engine~=nil and engine.settings.experimentalTeleport end)
 local adapter=GameAdapter.new(teleport)
 engine=AutoFarm.new(adapter,log,settings,modes)
 local scheduler=AutoModes.new(engine,log)
 local function runProfile(p)
  assert(not scheduler.active,"Pare a fila antes de iniciar manualmente")
  engine:start(p)
 end
 local ui=UI.mount(player:WaitForChild("PlayerGui"),{manager=manager,engine=engine,profiles=profiles,modes=modes,settings=settings,settingsModule=Settings,json=Json,log=log,scheduler=scheduler,storage=storage,runProfile=runProfile})
 local heartbeat=game:GetService("RunService").Heartbeat:Connect(function(dt)
  local ok,err=pcall(scheduler.tick,scheduler,dt)
  if not ok then scheduler:stop();log:record("ERROR",err)end
  ui:updateState(engine.state..(scheduler.active and " / FILA" or ""))
 end)
 local respawn=player.CharacterRemoving:Connect(function()scheduler:stop();log:record("STOP","Personagem removido")end)
 ui:onClose(function()scheduler:stop();heartbeat:Disconnect();respawn:Disconnect()end)
 log:record("INFO","MITI HUB 0.4.0; teleporte experimental, farm específico não integrado")
 -- Exposição explícita para integrações futuras pelo autor, sem código remoto.
 return {engine=engine,profiles=profiles,manager=manager,scheduler=scheduler,adapter=adapter,diagnostics=log}
end
return Main

end
local Main=requireModule("main")
if game==nil then return Main end
return Main.start()
