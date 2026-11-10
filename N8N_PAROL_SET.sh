#!/usr/bin/env bash
# =====================================================================
# N8N_PAROL_SET.sh — 2026-11-10 — «Aros Provodka - Parol Set» (ProvParolSet0001) — YANGI workflow
#
# MUAMMO: Pravodka foydalanuvchilari parolini unutadi; Supabase custom SMTP yo'q (o'z pochtasi faqat
#   jamoaga, soatiga 2 ta), shuning uchun email orqali tiklash ishlamaydi.
# YECHIM: Sozlama → «Rollar va foydalanuvchilar» → har user qatorida «Parol» tugmasi. Admin yangi parol
#   yozadi → POST https://n8n.arosmarket.com/webhook/aros-provodka-parol-set {token,user_id,password}
#   → n8n: token'ni Supabase /auth/v1/user bilan tekshiradi → profiles.role='admin' bo'lsa →
#   PUT /auth/v1/admin/users/{id} {password} («Supabase account 2» service_role kredensiali,
#   «Users v2 (email)» workflow'idagi bilan bir xil). Javobga parol/token chiqmaydi.
#
#   ssh root@37.27.15.184 'bash -s' < /Users/s1mple/Projects/pravodka/N8N_PAROL_SET.sh
# Keyin n8n UI: https://n8n.arosmarket.com/workflow/ProvParolSet0001 → Publish (Active).
# Qayta ishga tushirish xavfsiz — import:workflow o'sha id'ni yangilaydi.
# =====================================================================
set -euo pipefail
PROJECT=wNdKr8cHdx1jmPka   # «Aros Provodka - Users v2» egasi bo'lgan loyiha (shared_workflow)
TMP=/tmp/parol_set_wf.json
cat > "$TMP" <<'JSONEOF'
{
 "id": "ProvParolSet0001",
 "name": "Aros Provodka - Parol Set",
 "active": false,
 "nodes": [
  {
   "parameters": {
    "httpMethod": "POST",
    "path": "aros-provodka-parol-set",
    "responseMode": "responseNode",
    "options": {
     "allowedOrigins": "*"
    }
   },
   "id": "316c0e7e-9762-44fd-a49e-49b4e312d052",
   "name": "Webhook Parol",
   "type": "n8n-nodes-base.webhook",
   "typeVersion": 2.1,
   "position": [
    0,
    0
   ],
   "webhookId": "e2e31e11-cdba-41ec-a5ea-c72110e1b3fc"
  },
  {
   "parameters": {
    "jsCode": "// Aros Provodka — Parol Set · Tekshir\n// Kirish: {token (admin sessiya access_token), user_id (uuid), password (yangi parol)}\nconst w = $('Webhook Parol').first().json || {};\nlet b = w.body;\nif (typeof b === 'string') { try { b = JSON.parse(b); } catch (e) { b = {}; } }\nb = b || {};\nconst token = String(b.token || '').trim();\nconst uid = String(b.user_id || '').trim();\nconst pw = String(b.password || '');\nconst UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;\nlet err = null;\nif (!token) err = \"Sessiya yo'q — qayta kiring\";\nelse if (!UUID.test(uid)) err = \"user_id noto'g'ri\";\nelse if (pw.length < 6) err = \"Parol kamida 6 belgi bo'lsin\";\nelse if (pw.length > 72) err = \"Parol juda uzun\";\nreturn [{ json: { ok: !err, error: err, token, user_id: uid, password: pw } }];\n"
   },
   "id": "6750c9de-95c0-49cb-97c9-c563eea0d1b7",
   "name": "Tekshir",
   "type": "n8n-nodes-base.code",
   "typeVersion": 2,
   "position": [
    220,
    0
   ]
  },
  {
   "parameters": {
    "conditions": {
     "options": {
      "caseSensitive": true,
      "leftValue": "",
      "typeValidation": "loose",
      "version": 2
     },
     "conditions": [
      {
       "id": "cf0cbd34-d95f-471f-bab1-36c050c83d2f",
       "leftValue": "={{ $json.ok }}",
       "rightValue": true,
       "operator": {
        "type": "boolean",
        "operation": "true",
        "singleValue": true
       }
      }
     ],
     "combinator": "and"
    },
    "options": {}
   },
   "id": "a9bc9f05-ccee-4c5c-8155-1ed855ec087a",
   "name": "Yaroqli?",
   "type": "n8n-nodes-base.if",
   "typeVersion": 2.2,
   "position": [
    440,
    0
   ]
  },
  {
   "parameters": {
    "url": "https://kxzerccdpcltmzrxutlo.supabase.co/auth/v1/user",
    "sendHeaders": true,
    "headerParameters": {
     "parameters": [
      {
       "name": "apikey",
       "value": "sb_publishable_meO8FlGtAz1hmwNrrrgI6Q_PBh0T1rT"
      },
      {
       "name": "Authorization",
       "value": "=Bearer {{ $('Tekshir').first().json.token }}"
      }
     ]
    },
    "options": {
     "response": {
      "response": {
       "neverError": true
      }
     },
     "timeout": 15000
    }
   },
   "id": "96fc770a-d22e-4843-8f89-692edb4424db",
   "name": "Kim",
   "type": "n8n-nodes-base.httpRequest",
   "typeVersion": 4.2,
   "position": [
    680,
    -100
   ],
   "alwaysOutputData": true,
   "onError": "continueRegularOutput"
  },
  {
   "parameters": {
    "url": "=https://kxzerccdpcltmzrxutlo.supabase.co/rest/v1/profiles?select=id,role&id=eq.{{ $json.id || '00000000-0000-0000-0000-000000000000' }}",
    "authentication": "predefinedCredentialType",
    "nodeCredentialType": "supabaseApi",
    "options": {
     "response": {
      "response": {
       "neverError": true
      }
     },
     "timeout": 15000
    }
   },
   "id": "4a31e7fa-70b4-49fe-aa19-958219fe16f3",
   "name": "Rol",
   "type": "n8n-nodes-base.httpRequest",
   "typeVersion": 4.2,
   "position": [
    900,
    -100
   ],
   "alwaysOutputData": true,
   "executeOnce": true,
   "onError": "continueRegularOutput",
   "credentials": {
    "supabaseApi": {
     "id": "EYCiBXDeCAQoumkE",
     "name": "Supabase account 2"
    }
   }
  },
  {
   "parameters": {
    "jsCode": "// Aros Provodka — Parol Set · Ruxsat\n// Chaqiruvchi tokeni Supabase'da tekshirildi (Kim), roli profiles'dan (Rol). Faqat admin o'tadi.\nconst kim = $('Kim').first().json || {};\nconst rows = $('Rol').all().map(i => i.json).filter(r => r && r.id);\nconst t = $('Tekshir').first().json;\nlet err = null;\nif (!kim.id) err = \"Sessiya yaroqsiz yoki muddati o'tgan — qayta kiring\";\nelse if (!rows.length || rows[0].role !== 'admin') err = \"Faqat admin parol o'rnata oladi\";\nreturn [{ json: { ok: !err, error: err, user_id: t.user_id, password: t.password,\n  admin_id: kim.id || null, admin_email: kim.email || null } }];\n"
   },
   "id": "f445ad92-dc03-4d17-9c2b-105f42294287",
   "name": "Ruxsat",
   "type": "n8n-nodes-base.code",
   "typeVersion": 2,
   "position": [
    1120,
    -100
   ]
  },
  {
   "parameters": {
    "conditions": {
     "options": {
      "caseSensitive": true,
      "leftValue": "",
      "typeValidation": "loose",
      "version": 2
     },
     "conditions": [
      {
       "id": "1de776b4-6c79-4768-a5ca-80d1b22b546d",
       "leftValue": "={{ $json.ok }}",
       "rightValue": true,
       "operator": {
        "type": "boolean",
        "operation": "true",
        "singleValue": true
       }
      }
     ],
     "combinator": "and"
    },
    "options": {}
   },
   "id": "bd2fafd1-77aa-48f8-907d-91281e9a4170",
   "name": "Admin?",
   "type": "n8n-nodes-base.if",
   "typeVersion": 2.2,
   "position": [
    1340,
    -100
   ]
  },
  {
   "parameters": {
    "method": "PUT",
    "url": "=https://kxzerccdpcltmzrxutlo.supabase.co/auth/v1/admin/users/{{ $json.user_id }}",
    "authentication": "predefinedCredentialType",
    "nodeCredentialType": "supabaseApi",
    "sendBody": true,
    "specifyBody": "json",
    "jsonBody": "={{ JSON.stringify({ password: $json.password }) }}",
    "options": {
     "response": {
      "response": {
       "neverError": true
      }
     },
     "timeout": 20000
    }
   },
   "id": "ef02425b-4284-48e2-9070-b8456225bcc0",
   "name": "Parol Set",
   "type": "n8n-nodes-base.httpRequest",
   "typeVersion": 4.2,
   "position": [
    1580,
    -200
   ],
   "alwaysOutputData": true,
   "executeOnce": true,
   "onError": "continueRegularOutput",
   "credentials": {
    "supabaseApi": {
     "id": "EYCiBXDeCAQoumkE",
     "name": "Supabase account 2"
    }
   }
  },
  {
   "parameters": {
    "jsCode": "// Aros Provodka — Parol Set · Natija (Supabase admin javobini javob shakliga keltiradi)\nconst r = $input.first().json || {};\nconst p = $('Ruxsat').first().json || {};\nif (r.id) {\n  return [{ json: { ok: true, user_id: r.id, email: r.email || null, admin: p.admin_email || p.admin_id || null } }];\n}\nreturn [{ json: { ok: false, error: r.msg || r.message || r.error_description || r.error || 'Supabase admin xatosi' } }];\n"
   },
   "id": "ed6e48fd-b5ab-4127-93fa-ab5b0c99be51",
   "name": "Natija",
   "type": "n8n-nodes-base.code",
   "typeVersion": 2,
   "position": [
    1800,
    -200
   ]
  },
  {
   "parameters": {
    "jsCode": "// Parol/token javobga chiqmasin — faqat ok:false + sabab\nconst j = $input.first().json || {};\nreturn [{ json: { ok: false, error: j.error || 'Xato' } }];\n"
   },
   "id": "7e2f5a4e-8b64-41ee-a196-1dfef168bca2",
   "name": "Xato",
   "type": "n8n-nodes-base.code",
   "typeVersion": 2,
   "position": [
    1580,
    160
   ]
  },
  {
   "parameters": {
    "respondWith": "json",
    "responseBody": "={{ JSON.stringify($json) }}",
    "options": {
     "responseHeaders": {
      "entries": [
       {
        "name": "Access-Control-Allow-Origin",
        "value": "*"
       },
       {
        "name": "Access-Control-Allow-Methods",
        "value": "POST, OPTIONS"
       },
       {
        "name": "Access-Control-Allow-Headers",
        "value": "Content-Type"
       }
      ]
     }
    }
   },
   "id": "3b9fae4a-7f40-4079-bbb5-a5e929bd3097",
   "name": "Javob",
   "type": "n8n-nodes-base.respondToWebhook",
   "typeVersion": 1.5,
   "position": [
    2040,
    0
   ]
  }
 ],
 "connections": {
  "Webhook Parol": {
   "main": [
    [
     {
      "node": "Tekshir",
      "type": "main",
      "index": 0
     }
    ]
   ]
  },
  "Tekshir": {
   "main": [
    [
     {
      "node": "Yaroqli?",
      "type": "main",
      "index": 0
     }
    ]
   ]
  },
  "Yaroqli?": {
   "main": [
    [
     {
      "node": "Kim",
      "type": "main",
      "index": 0
     }
    ],
    [
     {
      "node": "Xato",
      "type": "main",
      "index": 0
     }
    ]
   ]
  },
  "Kim": {
   "main": [
    [
     {
      "node": "Rol",
      "type": "main",
      "index": 0
     }
    ]
   ]
  },
  "Rol": {
   "main": [
    [
     {
      "node": "Ruxsat",
      "type": "main",
      "index": 0
     }
    ]
   ]
  },
  "Ruxsat": {
   "main": [
    [
     {
      "node": "Admin?",
      "type": "main",
      "index": 0
     }
    ]
   ]
  },
  "Admin?": {
   "main": [
    [
     {
      "node": "Parol Set",
      "type": "main",
      "index": 0
     }
    ],
    [
     {
      "node": "Xato",
      "type": "main",
      "index": 0
     }
    ]
   ]
  },
  "Parol Set": {
   "main": [
    [
     {
      "node": "Natija",
      "type": "main",
      "index": 0
     }
    ]
   ]
  },
  "Natija": {
   "main": [
    [
     {
      "node": "Javob",
      "type": "main",
      "index": 0
     }
    ]
   ]
  },
  "Xato": {
   "main": [
    [
     {
      "node": "Javob",
      "type": "main",
      "index": 0
     }
    ]
   ]
  }
 },
 "settings": {
  "executionOrder": "v1",
  "timezone": "Asia/Tashkent",
  "executionTimeout": 60,
  "saveManualExecutions": true
 },
 "pinData": {},
 "meta": {
  "templateCredsSetupCompleted": true
 }
}
JSONEOF
python3 -c "import json,sys; json.load(open('$TMP')); print('JSON OK')"
docker cp "$TMP" n8n:/tmp/parol_set_wf.json
docker exec -u node n8n n8n import:workflow --input=/tmp/parol_set_wf.json --projectId="$PROJECT" 2>&1 | grep -v '^$' | tail -5
docker exec n8n-postgres psql -U n8n -d n8n -Atc "select id, name, active, json_array_length(nodes) as nodes from workflow_entity where id='ProvParolSet0001';"
docker exec n8n-postgres psql -U n8n -d n8n -Atc "select \"workflowId\", \"projectId\", role from shared_workflow where \"workflowId\"='ProvParolSet0001';"
echo "Endi n8n UI'da: https://n8n.arosmarket.com/workflow/ProvParolSet0001 → Publish (Active)."
