import { createClient } from '@/lib/supabase/server'
import { NextRequest, NextResponse } from 'next/server'

export async function POST(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  try {
    const { id } = await params
    const supabase = await createClient()
    
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    if (authError || !user) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })
    }

    const body = await request.json()
    const { recipientEmail, message } = body

    if (!recipientEmail) {
      return NextResponse.json({ error: 'Recipient email is required' }, { status: 400 })
    }

    const { data: letter, error: letterError } = await supabase
      .from('letters')
      .select('*, profiles(full_name, email)')
      .eq('id', id)
      .eq('user_id', user.id)
      .single()

    if (letterError || !letter) {
      return NextResponse.json({ error: 'Letter not found' }, { status: 404 })
    }

    if (letter.status !== 'approved') {
      return NextResponse.json({ error: 'Only approved letters can be sent' }, { status: 400 })
    }

    // TASK 8: Implement email sending
    // Check if email service is configured
    const resendApiKey = process.env.RESEND_API_KEY
    
    if (!resendApiKey) {
      console.warn('[Email] RESEND_API_KEY not configured, simulating email send')
      
      // Log for demo purposes
      console.log('[Email] Simulation:', {
        to: recipientEmail,
        from: letter.profiles?.email,
        subject: letter.title,
        content: letter.final_content,
        message: message
      })
      
      return NextResponse.json({ 
        success: true,
        message: 'Email sent successfully (simulated - configure RESEND_API_KEY for actual sending)'
      })
    }

    // Send actual email using Resend
    const emailContent = letter.final_content || letter.ai_draft_content || ''
    
    const emailHtml = `
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <style>
    body { font-family: Arial, sans-serif; line-height: 1.6; color: #333; }
    .header { background: #003366; color: white; padding: 20px; text-align: center; }
    .content { padding: 30px; white-space: pre-wrap; }
    .footer { background: #f5f5f5; padding: 20px; text-align: center; font-size: 12px; color: #666; }
    .message { background: #f0f8ff; border-left: 4px solid #003366; padding: 15px; margin-bottom: 20px; }
  </style>
</head>
<body>
  <div class="header">
    <h1>Legal Letter from Talk-To-My-Lawyer</h1>
  </div>
  <div class="content">
    ${message ? `<div class="message"><strong>Message from sender:</strong><br>${message}</div>` : ''}
    <div>${emailContent}</div>
  </div>
  <div class="footer">
    <p>This document has been reviewed and approved by a licensed attorney.</p>
    <p>Sent via Talk-To-My-Lawyer | www.talk-to-my-lawyer.com</p>
  </div>
</body>
</html>`

    try {
      const response = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${resendApiKey}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          from: 'Talk-To-My-Lawyer <noreply@talk-to-my-lawyer.com>',
          to: recipientEmail,
          subject: letter.title,
          html: emailHtml,
          reply_to: letter.profiles?.email
        })
      })

      if (!response.ok) {
        const errorData = await response.json()
        console.error('[Email] Resend API error:', errorData)
        throw new Error(errorData.message || 'Failed to send email')
      }

      const result = await response.json()
      console.log('[Email] Sent successfully:', result)

      return NextResponse.json({ 
        success: true,
        message: 'Email sent successfully',
        emailId: result.id
      })

    } catch (emailError: any) {
      console.error('[Email] Send error:', emailError)
      return NextResponse.json(
        { error: `Failed to send email: ${emailError.message}` },
        { status: 500 }
      )
    }

  } catch (error) {
    console.error('[Email] General error:', error)
    return NextResponse.json(
      { error: 'Failed to send email' },
      { status: 500 }
    )
  }
}