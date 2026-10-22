#!/usr/bin/env python3
"""Audit direct Chinese UI translation keys without changing model identifiers."""
from pathlib import Path
import re,json
from pathlib import Path
import re
root=Path.cwd()
# A small lexical walker, including nested string interpolation, avoids modifying comments.
def strings(s):
 def quoted(i):
  start=i;i+=1
  while i<len(s):
   if s[i]=='\\':
    if i+1<len(s) and s[i+1]=='(':
     i+=2;depth=1
     while i<len(s) and depth:
      if s[i]=='"':i=quoted(i)
      elif s[i]=='(':depth+=1;i+=1
      elif s[i]==')':depth-=1;i+=1
      else:i+=1
    else:i+=2
   elif s[i]=='"':return i+1
   else:i+=1
  return i
 i=0
 while i<len(s):
  if s.startswith('//',i):
   i=s.find('\n',i)
   if i<0:return
  elif s.startswith('/*',i):
   j=s.find('*/',i+2);i=len(s) if j<0 else j+2
  elif s.startswith('"""',i):
   j=s.find('"""',i+3);i=len(s) if j<0 else j+3
  elif s[i]=='"':
   j=quoted(i);yield i,j;i=j
  else:i+=1

data=json.loads(Path('Resources/Localization/en.json').read_text())
def norm(s):
 s=s[1:-1];out='';i=0;slot=0
 while i<len(s):
  if s.startswith('\\(',i):
   depth=1;j=i+2
   while j<len(s) and depth:
    if s[j]=='(':depth+=1
    elif s[j]==')':depth-=1
    j+=1
   out+='{'+str(slot)+'}';slot+=1;i=j
  elif s.startswith('\\n',i):out+='\n';i+=2
  elif s.startswith('\\"',i):out+='"';i+=2
  else:out+=s[i];i+=1
 return out
missing={}
for p in Path('Sources/Phos').glob('*.swift'):
 if p.name=='LocalizationCatalog.swift':continue
 s=p.read_text()
 for a,b in strings(s):
  if re.search('[\u4e00-\u9fff]',s[a:b]) and s[max(0,a-8):a]=='L10n.tr(':
   key=norm(s[a:b])
   if key not in data:missing[key]=p.name
result = {'status':'passed' if not missing else 'failed','catalogEntries':len(data),'missingDirectLiteralKeys':missing,'scope':'Direct UI translation literals; dynamic metadata and state are covered by workspace tests.'}
print(json.dumps(result,ensure_ascii=False,indent=2))
raise SystemExit(1 if missing else 0)
