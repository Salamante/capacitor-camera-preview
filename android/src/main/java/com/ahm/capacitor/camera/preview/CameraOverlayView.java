package com.ahm.capacitor.camera.preview;

import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.util.AttributeSet;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.TextView;

public class CameraOverlayView extends FrameLayout {
    
    // Properties
    private RectF cutoutRect;
    private int overlayColor;
    private int borderColor;
    private float borderWidth;
    private float cornerRadius;
    private String labelText;
    private int labelBackgroundColor;
    private int labelTextColor;
    
    // Paint objects
    private Paint overlayPaint;
    private Paint borderPaint;
    
    // UI Elements
    private TextView instructionLabel;
    private Button closeButton;
    private ValueAnimator pulseAnimator;
    
    // Callback for close button
    public interface OnCloseListener {
        void onClose();
    }
    private OnCloseListener onCloseListener;
    
    // Document types
    public enum DocumentType {
        ID_CARD,
        PASSPORT
    }
    
    public CameraOverlayView(Context context) {
        super(context);
        init();
    }
    
    public CameraOverlayView(Context context, AttributeSet attrs) {
        super(context, attrs);
        init();
    }
    
    public CameraOverlayView(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
        init();
    }
    
    private void init() {
        setWillNotDraw(false);
        
        // Initialize default values
        cutoutRect = new RectF();
        overlayColor = Color.parseColor("#80000000"); // Semi-transparent black
        borderColor = Color.WHITE;
        borderWidth = dpToPx(2);
        cornerRadius = dpToPx(8);
        labelText = "";
        labelBackgroundColor = Color.parseColor("#99000000"); // Semi-transparent black
        labelTextColor = Color.WHITE;
        
        // Initialize paint objects
        overlayPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        overlayPaint.setStyle(Paint.Style.FILL);
        overlayPaint.setColor(overlayColor);
        
        borderPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        borderPaint.setStyle(Paint.Style.STROKE);
        borderPaint.setColor(borderColor);
        borderPaint.setStrokeWidth(borderWidth);
    }
    
    public void configure(RectF cutoutRect, int overlayColor, int borderColor, 
                         float borderWidth, float cornerRadius, String labelText) {
        this.cutoutRect = cutoutRect;
        this.overlayColor = overlayColor;
        this.borderColor = borderColor;
        this.borderWidth = borderWidth;
        this.cornerRadius = cornerRadius;
        this.labelText = labelText;
        
        // Update paint objects
        overlayPaint.setColor(overlayColor);
        borderPaint.setColor(borderColor);
        borderPaint.setStrokeWidth(borderWidth);
        
        updateOverlay();
    }
    
    public void configureForDocument(DocumentType documentType, String labelText) {
        this.labelText = labelText;
        
        // Wait for view to be measured before calculating rect
        if (getWidth() == 0 || getHeight() == 0) {
            // Store document type for later use
            final DocumentType finalDocumentType = documentType;
            post(new Runnable() {
                @Override
                public void run() {
                    RectF rect = calculateDocumentRect(finalDocumentType);
                    configure(rect, overlayColor, borderColor, borderWidth, cornerRadius, labelText);
                }
            });
        } else {
            RectF rect = calculateDocumentRect(documentType);
            configure(rect, overlayColor, borderColor, borderWidth, cornerRadius, labelText);
        }
    }
    
    private RectF calculateDocumentRect(DocumentType documentType) {
        int width = getWidth();
        int height = getHeight();
        
        if (width == 0 || height == 0) {
            // If view hasn't been measured yet, return a default rect
            return new RectF(0, 0, 100, 100);
        }
        
        float aspectRatio;
        float padding = dpToPx(20);
        
        switch (documentType) {
            case ID_CARD:
                aspectRatio = 1.586f; // Standard ID card aspect ratio
                break;
            case PASSPORT:
                aspectRatio = 1.384f; // Standard passport aspect ratio
                padding = dpToPx(30);
                break;
            default:
                aspectRatio = 1.586f;
                break;
        }
        
        float availableWidth = width - (padding * 2);
        float availableHeight = height * (documentType == DocumentType.PASSPORT ? 0.5f : 0.4f);
        
        float rectWidth = availableWidth;
        float rectHeight = rectWidth / aspectRatio;
        
        // For ID card, increase height by 15%
        if (documentType == DocumentType.ID_CARD) {
            rectHeight *= 1.15f;
        }
        
        if (rectHeight > availableHeight) {
            rectHeight = availableHeight;
            rectWidth = rectHeight * aspectRatio;
            if (documentType == DocumentType.ID_CARD) {
                rectWidth /= 1.15f;
            }
        }
        
        float x = (width - rectWidth) / 2;
        float y = (height - rectHeight) / 2;
        
        return new RectF(x, y, x + rectWidth, y + rectHeight);
    }
    
    private void updateOverlay() {
        // Remove existing views
        removeAllViews();
        
        // Create instruction label if text is provided
        if (!labelText.isEmpty()) {
            createInstructionLabel();
        }
        
        // Create close button
        createCloseButton();
        
        invalidate();
    }
    
    private void createInstructionLabel() {
        instructionLabel = new TextView(getContext());
        instructionLabel.setText(labelText);
        instructionLabel.setTextColor(labelTextColor);
        instructionLabel.setGravity(Gravity.CENTER);
        instructionLabel.setTypeface(null, Typeface.BOLD);
        instructionLabel.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
        instructionLabel.setBackgroundColor(labelBackgroundColor);
        instructionLabel.setPadding(dpToPx(16), dpToPx(12), dpToPx(16), dpToPx(12));
        
        // Create rounded corners for the label
        android.graphics.drawable.GradientDrawable labelBackground = new android.graphics.drawable.GradientDrawable();
        labelBackground.setShape(android.graphics.drawable.GradientDrawable.RECTANGLE);
        labelBackground.setColor(labelBackgroundColor);
        labelBackground.setCornerRadius(dpToPx(20));
        instructionLabel.setBackground(labelBackground);
        
        // Position label above the cutout rectangle with better calculation
        FrameLayout.LayoutParams params = new FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        );
        params.gravity = Gravity.CENTER_HORIZONTAL | Gravity.TOP;
        
        // Calculate position based on cutout rect
        int topMargin = (int)(cutoutRect.top - dpToPx(70));
        if (topMargin < dpToPx(80)) { // Leave space for status bar and close button
            topMargin = dpToPx(80);
        }
        params.topMargin = topMargin;
        params.leftMargin = dpToPx(20);
        params.rightMargin = dpToPx(20);
        
        addView(instructionLabel, params);
    }
    
    private void createCloseButton() {
        closeButton = new Button(getContext());
        closeButton.setText("×"); // Use multiplication symbol for cleaner X
        closeButton.setTextColor(Color.WHITE);
        closeButton.setTextSize(TypedValue.COMPLEX_UNIT_SP, 24);
        closeButton.setTypeface(null, Typeface.NORMAL);
        
        // Create circular button with transparent background
        closeButton.setBackground(null);
        closeButton.setBackgroundColor(Color.parseColor("#80000000")); // Semi-transparent black
        closeButton.setPadding(0, 0, 0, 0);
        
        // Make it circular
        closeButton.post(new Runnable() {
            @Override
            public void run() {
                closeButton.setBackground(createCircularDrawable());
            }
        });
        
        // Position button in top-right corner
        FrameLayout.LayoutParams params = new FrameLayout.LayoutParams(
            dpToPx(44),
            dpToPx(44)
        );
        params.gravity = Gravity.TOP | Gravity.END;
        params.topMargin = dpToPx(50);
        params.rightMargin = dpToPx(20);
        
        closeButton.setOnClickListener(new OnClickListener() {
            @Override
            public void onClick(View v) {
                if (onCloseListener != null) {
                    onCloseListener.onClose();
                }
            }
        });
        
        addView(closeButton, params);
    }
    
    private android.graphics.drawable.Drawable createCircularDrawable() {
        android.graphics.drawable.GradientDrawable drawable = new android.graphics.drawable.GradientDrawable();
        drawable.setShape(android.graphics.drawable.GradientDrawable.OVAL);
        drawable.setColor(Color.parseColor("#80000000"));
        drawable.setStroke(dpToPx(1), Color.parseColor("#40FFFFFF"));
        return drawable;
    }
    
    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        
        if (cutoutRect.isEmpty()) {
            return;
        }
        
        // Draw overlay with cutout
        Path overlayPath = new Path();
        overlayPath.addRect(0, 0, getWidth(), getHeight(), Path.Direction.CW);
        
        // Create cutout path with rounded corners
        Path cutoutPath = new Path();
        cutoutPath.addRoundRect(cutoutRect, cornerRadius, cornerRadius, Path.Direction.CCW);
        
        // Subtract cutout from overlay
        overlayPath.op(cutoutPath, Path.Op.DIFFERENCE);
        
        // Draw overlay
        canvas.drawPath(overlayPath, overlayPaint);
        
        // Draw border around cutout
        canvas.drawRoundRect(cutoutRect, cornerRadius, cornerRadius, borderPaint);
    }
    
    @Override
    protected void onSizeChanged(int w, int h, int oldw, int oldh) {
        super.onSizeChanged(w, h, oldw, oldh);
        // Recalculate cutout rect if needed
        if (!cutoutRect.isEmpty()) {
            // Update overlay when size changes
            post(new Runnable() {
                @Override
                public void run() {
                    updateOverlay();
                }
            });
        }
    }
    
    // Public methods for updating overlay properties
    public void updateBorderColor(String colorString) {
        try {
            borderColor = Color.parseColor(colorString);
            borderPaint.setColor(borderColor);
            invalidate();
        } catch (IllegalArgumentException e) {
            // Invalid color format, ignore
        }
    }
    
    public void updateLabelText(String text) {
        this.labelText = text;
        if (instructionLabel != null) {
            instructionLabel.setText(text);
        }
    }
    
    public void startPulseAnimation() {
        stopPulseAnimation();
        
        pulseAnimator = ValueAnimator.ofFloat(1.0f, 1.05f);
        pulseAnimator.setDuration(600);
        pulseAnimator.setRepeatCount(ValueAnimator.INFINITE);
        pulseAnimator.setRepeatMode(ValueAnimator.REVERSE);
        pulseAnimator.addUpdateListener(new ValueAnimator.AnimatorUpdateListener() {
            @Override
            public void onAnimationUpdate(ValueAnimator animation) {
                float scale = (Float) animation.getAnimatedValue();
                setScaleX(scale);
                setScaleY(scale);
            }
        });
        pulseAnimator.start();
    }
    
    public void stopPulseAnimation() {
        if (pulseAnimator != null) {
            pulseAnimator.cancel();
            pulseAnimator = null;
            setScaleX(1.0f);
            setScaleY(1.0f);
        }
    }
    
    public void setOnCloseListener(OnCloseListener listener) {
        this.onCloseListener = listener;
    }
    
    private int dpToPx(float dp) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, dp, 
                getResources().getDisplayMetrics()));
    }
}